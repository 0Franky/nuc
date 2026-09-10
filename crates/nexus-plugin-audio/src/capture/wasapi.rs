use crate::constants::{DEFAULT_CHANNELS, DEFAULT_SAMPLE_RATE};

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
