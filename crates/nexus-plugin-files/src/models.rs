use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const DEFAULT_CHUNK_SIZE: usize = 64 * 1024; // 64 KB chunks

/// Metadata for a file transfer
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileMetadata {
    pub file_id: Uuid,
    pub file_name: String,
    pub file_size: u64,
    pub total_chunks: u32,
    pub chunk_size: u32,
    pub master_blake3_hash: [u8; 32],
}

impl FileMetadata {
    pub fn from_bytes(file_name: String, data: &[u8], chunk_size: usize) -> Self {
        let file_size = data.len() as u64;
        let total_chunks = if file_size == 0 {
            0
        } else {
            ((file_size as f64) / (chunk_size as f64)).ceil() as u32
        };
        let hash = blake3::hash(data);

        Self {
            file_id: Uuid::new_v4(),
            file_name,
            file_size,
            total_chunks,
            chunk_size: chunk_size as u32,
            master_blake3_hash: *hash.as_bytes(),
        }
    }
}

/// Individual encrypted file chunk with integrity proof
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileChunk {
    pub file_id: Uuid,
    pub chunk_index: u32,
    pub chunk_hash: [u8; 32],
    pub data: Vec<u8>,
}

impl FileChunk {
    pub fn new(file_id: Uuid, chunk_index: u32, data: Vec<u8>) -> Self {
        let hash = blake3::hash(&data);
        Self {
            file_id,
            chunk_index,
            chunk_hash: *hash.as_bytes(),
            data,
        }
    }

    /// Verifies that the chunk payload matches its BLAKE3 hash
    pub fn verify_integrity(&self) -> bool {
        let calculated = blake3::hash(&self.data);
        calculated.as_bytes() == &self.chunk_hash
    }
}

/// Transfer state
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferStatus {
    Pending,
    Transferring,
    Paused,
    Completed,
    Failed(String),
}
