use crate::constants::{DEFAULT_CHANNELS, DEFAULT_SAMPLE_RATE, SAMPLES_PER_10MS};
use crate::dsp::AudioRingBuffer;
use nexus_types::NexusResult;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Abstract Audio Capture Backend (WASAPI on Windows, PipeWire on Linux, CoreAudio on Apple)
pub trait AudioCaptureBackend: Send + Sync {
    fn start_capture(&self, ring_buffer: Arc<RwLock<AudioRingBuffer>>) -> NexusResult<()>;
    fn stop_capture(&self) -> NexusResult<()>;
    fn is_capturing(&self) -> bool;
}

/// Simulated & Loopback Audio Capture Backend for Native System Audio
pub struct WasapiLoopbackCapture {
    is_capturing: Arc<AtomicBool>,
}

impl WasapiLoopbackCapture {
    pub fn new() -> Self {
        Self {
            is_capturing: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl Default for WasapiLoopbackCapture {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioCaptureBackend for WasapiLoopbackCapture {
    fn start_capture(&self, ring_buffer: Arc<RwLock<AudioRingBuffer>>) -> NexusResult<()> {
        self.is_capturing.store(true, Ordering::SeqCst);
        let capturing = self.is_capturing.clone();

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(tokio::time::Duration::from_millis(10));
            let mut phase: f32 = 0.0;

            while capturing.load(Ordering::Relaxed) {
                interval.tick().await;

                let mut samples = Vec::with_capacity(SAMPLES_PER_10MS);
                for _ in 0..SAMPLES_PER_10MS {
                    let sample = (phase * 2.0 * std::f32::consts::PI).sin() * 0.5;
                    samples.push(sample);
                    phase = (phase + 440.0 / 48000.0) % 1.0;
                }

                let mut ring = ring_buffer.write().await;
                ring.push_slice(&samples);
            }
        });

        Ok(())
    }

    fn stop_capture(&self) -> NexusResult<()> {
        self.is_capturing.store(false, Ordering::SeqCst);
        Ok(())
    }

    fn is_capturing(&self) -> bool {
        self.is_capturing.load(Ordering::Relaxed)
    }
}

/// Generates standard 44-byte WAV header for continuous linear PCM streaming
pub fn generate_wav_header() -> [u8; 44] {
    let mut header = [0u8; 44];
    header[0..4].copy_from_slice(b"RIFF");
    let file_size: u32 = 0x7fff_ffff; // Continuous infinite stream
    header[4..8].copy_from_slice(&file_size.to_le_bytes());
    header[8..12].copy_from_slice(b"WAVE");

    header[12..16].copy_from_slice(b"fmt ");
    header[16..20].copy_from_slice(&16u32.to_le_bytes()); // Subchunk1Size
    header[20..22].copy_from_slice(&1u16.to_le_bytes());  // AudioFormat (1 = PCM)
    header[22..24].copy_from_slice(&(DEFAULT_CHANNELS as u16).to_le_bytes()); // 2 Channels
    header[24..28].copy_from_slice(&DEFAULT_SAMPLE_RATE.to_le_bytes()); // 48000 Hz
    let byte_rate: u32 = DEFAULT_SAMPLE_RATE * (DEFAULT_CHANNELS as u32) * 2; // 48000 * 2 * 2 = 192000
    header[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    header[32..34].copy_from_slice(&4u16.to_le_bytes()); // BlockAlign = Channels * 2
    header[34..36].copy_from_slice(&16u16.to_le_bytes()); // BitsPerSample = 16

    header[36..40].copy_from_slice(b"data");
    let data_size: u32 = 0x7fff_ffff;
    header[40..44].copy_from_slice(&data_size.to_le_bytes());

    header
}
