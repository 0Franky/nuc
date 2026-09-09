use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor};
use nexus_types::{DeviceId, NexusError, NexusResult};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{info, warn};
use uuid::Uuid;

use crate::models::{FileChunk, FileMetadata, TransferStatus, DEFAULT_CHUNK_SIZE};
use crate::session::FileTransferSession;

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
