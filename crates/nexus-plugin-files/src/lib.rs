use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor};
use nexus_types::{DeviceId, NexusError, NexusResult};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::RwLock;
use tracing::{info, warn};
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

/// File Streaming Plugin Actor
#[derive(Clone)]
pub struct FilePluginActor {
    pub device_id: DeviceId,
    pub active_sessions: Arc<RwLock<HashMap<Uuid, FileTransferSession>>>,
}

impl FilePluginActor {
    pub fn new(device_id: DeviceId) -> Self {
        Self {
            device_id,
            active_sessions: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Creates an outgoing file offer and registers session
    pub async fn create_offer(
        &self,
        file_name: String,
        data: &[u8],
        target_peer: DeviceId,
    ) -> (FileMetadata, Vec<FileChunk>) {
        let metadata = FileMetadata::from_bytes(file_name, data, DEFAULT_CHUNK_SIZE);
        let mut chunks = Vec::new();

        if metadata.total_chunks > 0 {
            for (i, chunk_slice) in data.chunks(DEFAULT_CHUNK_SIZE).enumerate() {
                chunks.push(FileChunk::new(
                    metadata.file_id,
                    i as u32,
                    chunk_slice.to_vec(),
                ));
            }
        }

        let session = FileTransferSession::new(metadata.clone(), self.device_id, target_peer);
        let mut sessions = self.active_sessions.write().await;
        sessions.insert(metadata.file_id, session);

        (metadata, chunks)
    }

    /// Handles an incoming chunk and validates its BLAKE3 hash
    pub async fn process_incoming_chunk(&self, chunk: FileChunk) -> NexusResult<bool> {
        // Defensive check: reject corrupted chunk
        if !chunk.verify_integrity() {
            warn!("Rejected corrupted file chunk {} for file {}", chunk.chunk_index, chunk.file_id);
            return Err(NexusError::Crypto("Corrupted chunk BLAKE3 mismatch".into()));
        }

        let mut sessions = self.active_sessions.write().await;
        let session = sessions.get_mut(&chunk.file_id).ok_or_else(|| {
            NexusError::Protocol(format!("Transfer session not found: {}", chunk.file_id))
        })?;

        let chunk_len = chunk.data.len() as u64;
        session.received_chunks.insert(chunk.chunk_index);
        session.chunk_storage.insert(chunk.chunk_index, chunk.data);
        session.bytes_transferred += chunk_len;
        session.status = TransferStatus::Transferring;

        // Check if 100% complete
        if session.received_chunks.len() as u32 == session.metadata.total_chunks {
            // Assemble and verify master BLAKE3 hash
            let mut assembled = Vec::with_capacity(session.metadata.file_size as usize);
            for i in 0..session.metadata.total_chunks {
                if let Some(c) = session.chunk_storage.get(&i) {
                    assembled.extend_from_slice(c);
                }
            }

            let master_hash = blake3::hash(&assembled);
            if master_hash.as_bytes() != &session.metadata.master_blake3_hash {
                session.status = TransferStatus::Failed("Master hash mismatch".into());
                return Err(NexusError::Crypto("Assembled file master hash mismatch".into()));
            }

            session.status = TransferStatus::Completed;
            info!("File transfer {} ('{}') successfully completed and verified!", session.metadata.file_id, session.metadata.file_name);
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// Assembles completed file bytes
    pub async fn get_completed_file(&self, file_id: Uuid) -> NexusResult<Vec<u8>> {
        let sessions = self.active_sessions.read().await;
        let session = sessions.get(&file_id).ok_or_else(|| {
            NexusError::Protocol(format!("Session {} not found", file_id))
        })?;

        if session.status != TransferStatus::Completed {
            return Err(NexusError::Protocol("File transfer is not yet completed".into()));
        }

        let mut assembled = Vec::with_capacity(session.metadata.file_size as usize);
        for i in 0..session.metadata.total_chunks {
            if let Some(c) = session.chunk_storage.get(&i) {
                assembled.extend_from_slice(c);
            } else {
                return Err(NexusError::Protocol("Missing chunk during assembly".into()));
            }
        }

        Ok(assembled)
    }

    pub fn clone_handle(&self) -> Arc<Self> {
        Arc::new(Self {
            device_id: self.device_id,
            active_sessions: self.active_sessions.clone(),
        })
    }
}

#[async_trait]
impl NexusActor for FilePluginActor {
    fn name(&self) -> &'static str {
        "nexus-plugin-files"
    }

    async fn run(&mut self, _bus: EventBus) -> NexusResult<()> {
        info!("Nexus Plugin Files actor started.");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_file_chunking_and_integrity_verification() {
        let actor = FilePluginActor::new(DeviceId::new_random());
        let test_data = b"Hello Nexus Universal Continuity! Fast P2P chunked file streaming verified with BLAKE3.";
        let (metadata, chunks) = actor.create_offer("test.txt".into(), test_data, DeviceId::new_random()).await;

        assert_eq!(metadata.file_name, "test.txt");
        assert_eq!(metadata.file_size, test_data.len() as u64);
        assert_eq!(chunks.len(), 1);
        assert!(chunks[0].verify_integrity());

        // Process chunk on receiving end
        let completed = actor.process_incoming_chunk(chunks[0].clone()).await.unwrap();
        assert!(completed);

        let assembled = actor.get_completed_file(metadata.file_id).await.unwrap();
        assert_eq!(assembled, test_data);
    }

    #[tokio::test]
    async fn test_corrupted_chunk_blake3_rejection() {
        let actor = FilePluginActor::new(DeviceId::new_random());
        let test_data = b"Secret data to be verified";
        let (_metadata, mut chunks) = actor.create_offer("secret.bin".into(), test_data, DeviceId::new_random()).await;

        // Tamper with a single byte in chunk data
        chunks[0].data[0] ^= 0xFF;
        assert!(!chunks[0].verify_integrity());

        // Should return error and reject corrupted chunk
        let res = actor.process_incoming_chunk(chunks[0].clone()).await;
        assert!(res.is_err());
    }

    #[tokio::test]
    async fn test_resumable_transfer_missing_chunks() {
        let actor = FilePluginActor::new(DeviceId::new_random());
        // 150 KB payload -> 3 chunks of 64 KB
        let test_data = vec![0x42u8; 150 * 1024];
        let (metadata, chunks) = actor.create_offer("large_file.iso".into(), &test_data, DeviceId::new_random()).await;
        assert_eq!(chunks.len(), 3);

        // Send chunk 0 and chunk 2 (chunk 1 lost/missing)
        let c0 = actor.process_incoming_chunk(chunks[0].clone()).await.unwrap();
        assert!(!c0);

        let c2 = actor.process_incoming_chunk(chunks[2].clone()).await.unwrap();
        assert!(!c2);

        {
            let sessions = actor.active_sessions.read().await;
            let session = sessions.get(&metadata.file_id).unwrap();
            assert_eq!(session.missing_chunks(), vec![1]);
            assert_eq!(session.status, TransferStatus::Transferring);
        }

        // Resume: Send missing chunk 1
        let c1 = actor.process_incoming_chunk(chunks[1].clone()).await.unwrap();
        assert!(c1, "File must be complete after missing chunk is received");

        let assembled = actor.get_completed_file(metadata.file_id).await.unwrap();
        assert_eq!(assembled, test_data);
    }

    #[tokio::test]
    async fn test_zero_byte_file_handling() {
        let actor = FilePluginActor::new(DeviceId::new_random());
        let (metadata, chunks) = actor.create_offer("empty.txt".into(), b"", DeviceId::new_random()).await;

        assert_eq!(metadata.file_size, 0);
        assert_eq!(metadata.total_chunks, 0);
        assert_eq!(chunks.len(), 0);
    }
}
