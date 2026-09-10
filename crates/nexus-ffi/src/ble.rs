//! BLE telemetry is separate from LAN discovery: advertisements never create peers.
use std::collections::{BTreeSet, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use serde::Serialize;
use tokio::sync::watch;
use uuid::Uuid;

const SAMPLE_TTL: Duration = Duration::from_secs(10);
const MAX_PEERS: usize = 64;
const MAX_SAMPLES: usize = 256;
const NEXUS_SERVICE: Uuid = Uuid::from_u128(0x00002847_0000_1000_8000_00805f9b34fb);

#[derive(Clone, Serialize)]
pub struct BleSample {
    pub peer_id: Uuid,
    pub rssi: i16,
    pub observed_at_ms: u64,
    pub sequence: u64,
}

struct ScanState {
    status: &'static str,
    error: Option<String>,
    sequence: u64,
    samples: VecDeque<(BleSample, Instant)>,
}

pub struct BleMonitor {
    enabled: watch::Sender<bool>,
    state: Mutex<ScanState>,
    local_id: Uuid,
}

impl BleMonitor {
    pub fn new(local_id: Uuid) -> Arc<Self> {
        let (enabled, _) = watch::channel(false);
        Arc::new(Self { enabled, local_id, state: Mutex::new(ScanState {
            status: "disabled", error: None, sequence: 0, samples: VecDeque::new(),
        }) })
    }

    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.send_replace(enabled);
        if !enabled {
            let mut state = self.state.lock().unwrap();
            state.samples.clear();
            state.status = "disabled";
            state.error = None;
        }
    }

    pub fn snapshot(&self) -> serde_json::Value {
        let mut state = self.state.lock().unwrap();
        state.samples.retain(|(_, seen)| seen.elapsed() < SAMPLE_TTL);
        serde_json::json!({
            "ble_samples": state.samples.iter().map(|(sample, _)| sample).collect::<Vec<_>>(),
            "ble_scan_status": state.status,
            "ble_scan_error": state.error,
        })
    }

    fn set_status(&self, status: &'static str, error: Option<String>) {
        let mut state = self.state.lock().unwrap();
        if !*self.enabled.borrow() {
            state.status = "disabled";
            state.error = None;
            state.samples.clear();
            return;
        }
        state.status = status;
        state.error = error;
        if status != "scanning" { state.samples.clear(); }
    }

    fn record(&self, data: &[u8], rssi: i16) {
        let Some(peer_id) = decode_peer(data) else { return; };
        if peer_id == self.local_id || !(-127..=-1).contains(&rssi) || !*self.enabled.borrow() { return; }
        let mut state = self.state.lock().unwrap();
        state.samples.retain(|(_, seen)| seen.elapsed() < SAMPLE_TTL);
        let identities: BTreeSet<_> = state.samples.iter().map(|(sample, _)| sample.peer_id).collect();
        if !identities.contains(&peer_id) && identities.len() >= MAX_PEERS { return; }
        if state.samples.len() >= MAX_SAMPLES { state.samples.pop_front(); }
        state.sequence = state.sequence.wrapping_add(1);
        let sequence = state.sequence;
        let observed_at_ms = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        state.samples.push_back((BleSample { peer_id, rssi, observed_at_ms, sequence }, Instant::now()));
    }

    #[cfg(any(target_os = "windows", target_os = "linux"))]
    pub fn start(self: &Arc<Self>) {
        let monitor = Arc::clone(self);
        tokio::spawn(async move {
            let mut enabled = monitor.enabled.subscribe();
            loop {
                if !*enabled.borrow_and_update() {
                    monitor.set_status("disabled", None);
                    if enabled.changed().await.is_err() { break; }
                    continue;
                }
                monitor.set_status("starting", None);
                if let Err(error) = monitor.scan_session(&mut enabled).await {
                    monitor.set_status("unavailable", Some(error));
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_secs(10)) => {},
                        _ = enabled.changed() => {},
                    }
                }
            }
        });
    }

    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    pub fn start(self: &Arc<Self>) {}

    #[cfg(any(target_os = "windows", target_os = "linux"))]
    async fn scan_session(&self, enabled: &mut watch::Receiver<bool>) -> Result<(), String> {
        use btleplug::api::{Central, CentralEvent, CentralState, Manager as _, Peripheral, ScanFilter};
        use btleplug::platform::Manager;
        use futures_util::StreamExt;
        let adapter = tokio::time::timeout(Duration::from_secs(10), async {
            let manager = Manager::new().await.map_err(|e| e.to_string())?;
            for adapter in manager.adapters().await.map_err(|e| e.to_string())? {
                if adapter.adapter_state().await.ok() == Some(CentralState::PoweredOn) {
                    return Ok(adapter);
                }
            }
            Err::<btleplug::platform::Adapter, String>("No powered Bluetooth adapter available".to_string())
        }).await.map_err(|_| "Bluetooth adapter discovery timed out".to_string())??;
        if !*enabled.borrow() { return Ok(()); }
        let mut events = tokio::time::timeout(Duration::from_secs(5), adapter.events()).await
            .map_err(|_| "Bluetooth event subscription timed out".to_string())?.map_err(|e| e.to_string())?;
        let started = tokio::time::timeout(Duration::from_secs(10), adapter.start_scan(ScanFilter { services: vec![NEXUS_SERVICE] })).await;
        if !matches!(started, Ok(Ok(()))) {
            let _ = tokio::time::timeout(Duration::from_secs(5), adapter.stop_scan()).await;
            return Err(match started { Ok(Err(error)) => error.to_string(), _ => "Bluetooth scan start timed out".to_string() });
        }
        self.set_status("scanning", None);
        let result = loop {
            tokio::select! {
                changed = enabled.changed() => {
                    if changed.is_err() || !*enabled.borrow_and_update() { break Ok(()); }
                },
                event = events.next() => {
                    let Some(event) = event else { break Err("Bluetooth event stream ended".to_string()); };
                    // BlueZ discovery can replay cached devices; only RSSI events
                    // advance Linux freshness. WinRT emits DeviceUpdated after
                    // every received advertisement, including unchanged RSSI.
                    let (id, fresh_rssi) = match event {
                        #[cfg(target_os = "linux")]
                        CentralEvent::RssiUpdate { id, rssi } => (id, Some(rssi)),
                        #[cfg(target_os = "windows")]
                        CentralEvent::DeviceDiscovered(id) | CentralEvent::DeviceUpdated(id) => (id, None),
                        CentralEvent::StateUpdate(CentralState::PoweredOff) => {
                            break Err("Bluetooth adapter is powered off".to_string());
                        },
                        _ => continue,
                    };
                    let Ok(peripheral) = adapter.peripheral(&id).await else { continue; };
                    let Ok(Ok(Some(properties))) = tokio::time::timeout(Duration::from_secs(2), peripheral.properties()).await else { continue; };
                    if let (Some(data), Some(rssi)) = (properties.service_data.get(&NEXUS_SERVICE), fresh_rssi.or(properties.rssi)) {
                        self.record(data, rssi);
                    }
                },
            }
        };
        let _ = tokio::time::timeout(Duration::from_secs(5), adapter.stop_scan()).await;
        result
    }
}

fn decode_peer(data: &[u8]) -> Option<Uuid> {
    if data.len() != 17 || data[0] != 1 { return None; }
    let id = Uuid::from_slice(&data[1..]).ok()?;
    if id.is_nil() { None } else { Some(id) }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn advertisement(id: Uuid) -> Vec<u8> {
        let mut data = vec![1];
        data.extend_from_slice(id.as_bytes());
        data
    }
    #[test]
    fn requires_exact_versioned_identity() {
        let id = Uuid::parse_str("00112233-4455-6677-8899-aabbccddeeff").unwrap();
        let data = advertisement(id);
        assert_eq!(decode_peer(&data), Some(id));
        assert!(decode_peer(&data[..16]).is_none());
        assert!(decode_peer(&[data.clone(), vec![0]].concat()).is_none());
        let mut wrong_version = data;
        wrong_version[0] = 2;
        assert!(decode_peer(&wrong_version).is_none());
        assert!(decode_peer(&advertisement(Uuid::nil())).is_none());
    }
    #[test]
    fn samples_require_scan_consent_and_exclude_self_and_invalid_rssi() {
        let local = Uuid::new_v4();
        let peer = Uuid::new_v4();
        let monitor = BleMonitor::new(local);
        monitor.record(&advertisement(peer), -50);
        assert_eq!(monitor.snapshot()["ble_samples"].as_array().unwrap().len(), 0);
        monitor.set_enabled(true);
        monitor.record(&advertisement(local), -50);
        monitor.record(&advertisement(peer), 127);
        assert_eq!(monitor.snapshot()["ble_samples"].as_array().unwrap().len(), 0);
        monitor.record(&advertisement(peer), -50);
        monitor.record(&advertisement(peer), -51);
        let snapshot = monitor.snapshot();
        assert_eq!(snapshot["ble_samples"].as_array().unwrap().len(), 2);
        assert_eq!(snapshot["ble_samples"][1]["sequence"], 2);
        assert_eq!(snapshot["ble_samples"][1]["rssi"], -51);
        monitor.set_enabled(false);
        assert_eq!(monitor.snapshot()["ble_samples"].as_array().unwrap().len(), 0);
    }
    #[test]
    fn expired_samples_are_removed_and_storage_is_bounded() {
        let monitor = BleMonitor::new(Uuid::new_v4());
        monitor.set_enabled(true);
        for _ in 0..100 { monitor.record(&advertisement(Uuid::new_v4()), -60); }
        assert_eq!(monitor.snapshot()["ble_samples"].as_array().unwrap().len(), MAX_PEERS);
        for (_, seen) in monitor.state.lock().unwrap().samples.iter_mut() { *seen = Instant::now() - SAMPLE_TTL; }
        assert!(monitor.snapshot()["ble_samples"].as_array().unwrap().is_empty());
        let peer = Uuid::new_v4();
        for _ in 0..300 { monitor.record(&advertisement(peer), -60); }
        assert_eq!(monitor.snapshot()["ble_samples"].as_array().unwrap().len(), MAX_SAMPLES);
    }
}
