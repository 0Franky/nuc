pub mod wasapi;

pub use wasapi::{generate_wav_header, AudioCaptureBackend, WasapiLoopbackCapture};
