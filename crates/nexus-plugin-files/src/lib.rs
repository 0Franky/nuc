pub mod actor;
pub mod models;
pub mod session;

pub use actor::FilePluginActor;
pub use models::{FileChunk, FileMetadata, TransferStatus, DEFAULT_CHUNK_SIZE};
pub use session::FileTransferSession;

#[cfg(test)]
mod tests {
    use super::*;
    use nexus_types::DeviceId;

    #[tokio::test]
    async fn test_file_chunking_and_integrity_verification() {
        let actor = FilePluginActor::new(DeviceId::new_random());
        let target = DeviceId::new_random();

        // 150 KB sample payload
        let sample_data = vec![0xAB; 150 * 1024];
        let file_name = "test_document.pdf".to_string();

        let (metadata, chunks) = actor.create_offer(file_name, &sample_data, target).await;

        assert_eq!(metadata.total_chunks, 3); // 64KB + 64KB + 22KB
        assert_eq!(chunks.len(), 3);

        // Simulate receiver receiving chunks
        let receiver_actor = FilePluginActor::new(target);
        // Register incoming offer
        let session = FileTransferSession::new(metadata.clone(), actor.device_id, target);
        receiver_actor
            .active_sessions
            .write()
            .await
            .insert(metadata.file_id, session);

        // Process chunks 0, 1, 2
        for chunk in chunks {
            let res = receiver_actor.process_incoming_chunk(chunk).await;
            assert!(res.is_ok());
        }

        // Verify assembled bytes
        let assembled = receiver_actor
            .get_completed_file(metadata.file_id)
            .await
            .unwrap();
        assert_eq!(assembled.len(), sample_data.len());
        assert_eq!(assembled, sample_data);
    }

    #[tokio::test]
    async fn test_corrupted_chunk_blake3_rejection() {
        let actor = FilePluginActor::new(DeviceId::new_random());
        let mut chunk = FileChunk::new(uuid::Uuid::new_v4(), 0, vec![1, 2, 3, 4]);

        // Tamper with data without updating hash
        chunk.data[0] = 99;

        assert!(!chunk.verify_integrity());
        let res = actor.process_incoming_chunk(chunk).await;
        assert!(res.is_err());
    }

    #[tokio::test]
    async fn test_zero_byte_file_handling() {
        let actor = FilePluginActor::new(DeviceId::new_random());
        let target = DeviceId::new_random();

        let (meta, chunks) = actor.create_offer("empty.txt".into(), &[], target).await;
        assert_eq!(meta.total_chunks, 0);
        assert_eq!(meta.file_size, 0);
        assert!(chunks.is_empty());
    }

    #[tokio::test]
    async fn test_resumable_transfer_missing_chunks() {
        let meta = FileMetadata {
            file_id: uuid::Uuid::new_v4(),
            file_name: "test.iso".into(),
            file_size: 4 * 64 * 1024,
            total_chunks: 4,
            chunk_size: 64 * 1024,
            master_blake3_hash: [0u8; 32],
        };

        let mut session =
            FileTransferSession::new(meta, DeviceId::new_random(), DeviceId::new_random());

        session.received_chunks.insert(0);
        session.received_chunks.insert(2);

        let missing = session.missing_chunks();
        assert_eq!(missing, vec![1, 3]);
        assert_eq!(session.progress_percentage(), 50.0);
    }
}
