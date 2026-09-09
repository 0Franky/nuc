use nexus_types::DeviceId;
use std::collections::{HashMap, HashSet};
use std::time::Instant;

use crate::models::{FileMetadata, TransferStatus};

/// Active File Transfer Session State
pub struct FileTransferSession {
    pub metadata: FileMetadata,
    pub sender: DeviceId,
    pub receiver: DeviceId,
    pub received_chunks: HashSet<u32>,
    pub chunk_storage: HashMap<u32, Vec<u8>>,
    pub bytes_transferred: u64,
    pub status: TransferStatus,
    pub start_time: Instant,
}

impl FileTransferSession {
    pub fn new(metadata: FileMetadata, sender: DeviceId, receiver: DeviceId) -> Self {
        Self {
            metadata,
            sender,
            receiver,
            received_chunks: HashSet::new(),
            chunk_storage: HashMap::new(),
            bytes_transferred: 0,
            status: TransferStatus::Pending,
            start_time: Instant::now(),
        }
    }

    pub fn progress_percentage(&self) -> f32 {
        if self.metadata.total_chunks == 0 {
            return 100.0;
        }
        (self.received_chunks.len() as f32 / self.metadata.total_chunks as f32) * 100.0
    }

    pub fn speed_mbps(&self) -> f32 {
        let elapsed = self.start_time.elapsed().as_secs_f32();
        if elapsed <= 0.001 {
            return 0.0;
        }
        (self.bytes_transferred as f32 / (1024.0 * 1024.0)) / elapsed
    }

    pub fn missing_chunks(&self) -> Vec<u32> {
        (0..self.metadata.total_chunks)
            .filter(|i| !self.received_chunks.contains(i))
            .collect()
    }
}
