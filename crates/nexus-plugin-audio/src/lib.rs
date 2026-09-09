pub mod actor;
pub mod capture;
pub mod constants;
pub mod dsp;
pub mod volume;
pub mod web;

pub use actor::AudioPluginActor;
pub use capture::{generate_wav_header, AudioCaptureBackend, WasapiLoopbackCapture};
pub use constants::{DEFAULT_CHANNELS, DEFAULT_SAMPLE_RATE, SAMPLES_PER_10MS};
pub use dsp::{AdaptiveJitterBuffer, AudioRingBuffer, DriftResampler};
pub use volume::{set_windows_master_volume, toggle_pc_speakers_mute};

#[cfg(test)]
mod tests {
    use super::*;
    use nexus_actor_system::EventBus;
    use nexus_types::DeviceId;
    use std::sync::atomic::Ordering;
    use std::sync::Arc;
    use tokio::sync::RwLock;

    #[test]
    fn test_lock_free_ring_buffer() {
        let mut rb = AudioRingBuffer::new(1024);
        let samples = [0.1f32, 0.2, 0.3, 0.4, 0.5];

        let written = rb.push_slice(&samples);
        assert_eq!(written, 5);
        assert_eq!(rb.available_to_read(), 5);

        let mut out = [0.0f32; 5];
        let read = rb.pop_slice(&mut out);
        assert_eq!(read, 5);
        assert_eq!(out, samples);
        assert_eq!(rb.available_to_read(), 0);
    }

    #[test]
    fn test_ring_buffer_overflow_protection() {
        let mut rb = AudioRingBuffer::new(10);
        let samples = [1.0f32; 15];

        let written = rb.push_slice(&samples);
        assert_eq!(written, 10);
    }

    #[test]
    fn test_adaptive_jitter_buffer() {
        let mut jb = AdaptiveJitterBuffer::new(10.0);
        jb.push_packet(1, 1000, vec![1, 2, 3]);
        jb.push_packet(2, 2000, vec![4, 5, 6]);

        let frame = jb.pop_frame();
        assert_eq!(frame, Some(vec![1, 2, 3]));
    }

    #[test]
    fn test_jitter_buffer_out_of_order_packets() {
        let mut jb = AdaptiveJitterBuffer::new(10.0);
        jb.push_packet(2, 2000, vec![4, 5, 6]);
        jb.push_packet(1, 1000, vec![1, 2, 3]);

        let frame = jb.pop_frame();
        assert_eq!(frame, Some(vec![1, 2, 3]));
    }

    #[test]
    fn test_drift_resampler_linear() {
        let mut resampler = DriftResampler::new();
        resampler.set_drift_adjustment(1.002);

        let input = [1.0f32; 100];
        let mut output = [0.0f32; 100];

        let written = resampler.process_linear(&input, &mut output);
        assert!(written > 95);
    }

    #[test]
    fn test_volume_clamping_bounds() {
        let actor = AudioPluginActor::new(DeviceId::new_random());
        let rt = tokio::runtime::Runtime::new().unwrap();

        rt.block_on(async {
            actor.set_volume(1.5).await;
            assert_eq!(*actor.master_volume.read().await, 1.0);

            actor.set_volume(-0.5).await;
            assert_eq!(*actor.master_volume.read().await, 0.0);
        });
    }

    #[test]
    fn test_audio_relay_lifecycle() {
        let (bus, mut cmd_rx) = EventBus::new(10, 10);
        let actor = AudioPluginActor::new(DeviceId::new_random());
        let peer_id = DeviceId::new_random();
        let rt = tokio::runtime::Runtime::new().unwrap();

        rt.block_on(async {
            tokio::spawn(async move {
                while let Some(_) = cmd_rx.recv().await {}
            });
            assert!(actor.start_streaming_to_peer(&bus, peer_id).await.is_ok());
            assert!(actor.is_streaming.load(Ordering::SeqCst));

            assert!(actor.stop_streaming(&bus).await.is_ok());
            assert!(!actor.is_streaming.load(Ordering::SeqCst));
        });
    }

    #[test]
    fn test_wasapi_loopback_capture_and_packetizer() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let rb = Arc::new(RwLock::new(AudioRingBuffer::new(4800)));
            let capture = WasapiLoopbackCapture::new();
            assert!(capture.start_capture(rb.clone()).is_ok());
            assert!(capture.is_capturing());
            assert!(capture.stop_capture().is_ok());
            assert!(!capture.is_capturing());
        });
    }

    #[test]
    fn test_wav_header_generation() {
        let header = generate_wav_header();
        assert_eq!(&header[0..4], b"RIFF");
        assert_eq!(&header[8..12], b"WAVE");
        assert_eq!(&header[12..16], b"fmt ");
        assert_eq!(&header[36..40], b"data");
    }

    #[tokio::test]
    async fn test_volume_and_mute_control() {
        let actor = AudioPluginActor::new(DeviceId::new_random());
        assert_eq!(*actor.master_volume.read().await, 0.85);
        assert!(!actor.is_muted.load(Ordering::SeqCst));

        // Test volume set
        actor.set_volume(0.42).await;
        assert_eq!(*actor.master_volume.read().await, 0.42);

        // Test toggle mute
        assert!(actor.toggle_mute());
        assert!(actor.is_muted.load(Ordering::SeqCst));

        // Setting volume > 0 automatically unmutes
        actor.set_volume(0.70).await;
        assert!(!actor.is_muted.load(Ordering::SeqCst));

        // Explicit set mute
        actor.set_mute(true);
        assert!(actor.is_muted.load(Ordering::SeqCst));
    }
}
