pub mod actor;
pub mod session;

pub use actor::MediaPluginActor;
pub use session::{append_log, ActiveMediaSession};

#[cfg(test)]
mod tests {
    use super::*;
    use nexus_actor_system::{EventBus, NexusActor, NexusCommand, NexusEvent};
    use nexus_protocol::{MediaPayload, PacketPayload};
    use nexus_types::DeviceId;

    #[tokio::test]
    async fn test_media_playback_update_and_handoff_cycle() {
        let (bus, mut cmd_rx) = EventBus::new(100, 100);

        let pc_id = DeviceId::new_random();
        let phone_id = DeviceId::new_random();

        let pc_media_actor = MediaPluginActor::new(pc_id);
        let phone_media_actor = MediaPluginActor::new(phone_id);

        // 1. PC starts playing YouTube at 14:22 (862,000 ms)
        pc_media_actor
            .update_local_playback(
                &bus,
                "YouTube (Chrome)".into(),
                "Rust Concurrency in Depth".into(),
                "https://youtube.com/watch?v=rust101".into(),
                862_000,
                1_800_000,
                true,
            )
            .await;

        let session = pc_media_actor.get_current_session().await.unwrap();
        assert_eq!(session.position_ms, 862_000);
        assert!(session.is_playing);

        // 2. User walks away -> PC offers handoff to Phone
        pc_media_actor
            .offer_handoff_to_peer(&bus, phone_id)
            .await
            .unwrap();

        // Check that command was sent
        let cmd = cmd_rx.recv().await.expect("No command received on bus");
        match cmd {
            NexusCommand::SendPacket { target, packet } => {
                assert_eq!(target, phone_id);
                if let PacketPayload::Media(MediaPayload::OfferHandoff {
                    position_ms,
                    media_title,
                    session_id,
                    ..
                }) = packet.payload
                {
                    assert_eq!(position_ms, 862_000);
                    assert_eq!(media_title, "Rust Concurrency in Depth");

                    // 3. Phone accepts handoff
                    phone_media_actor
                        .accept_handoff(&bus, pc_id, session_id.clone(), position_ms)
                        .await
                        .unwrap();

                    // 4. PC pauses local playback upon acceptance
                    pc_media_actor
                        .on_handoff_accepted_by_remote(&session_id)
                        .await
                        .unwrap();
                } else {
                    panic!("Unexpected payload");
                }
            }
            _ => panic!("Unexpected command"),
        }

        // Verify PC state is now paused
        let updated_session = pc_media_actor.get_current_session().await.unwrap();
        assert!(!updated_session.is_playing);
    }

    #[tokio::test]
    async fn test_cannot_offer_handoff_without_active_session() {
        let (bus, _rx) = EventBus::new(10, 10);
        let pc_id = DeviceId::new_random();
        let phone_id = DeviceId::new_random();

        let actor = MediaPluginActor::new(pc_id);

        // Attempting to offer handoff when no video session is initialized must return an Err
        let result = actor.offer_handoff_to_peer(&bus, phone_id).await;
        assert!(
            result.is_err(),
            "Offering handoff without active media must fail"
        );
    }

    #[tokio::test]
    async fn test_unmatched_session_id_rejection() {
        let (bus, _rx) = EventBus::new(10, 10);
        let pc_id = DeviceId::new_random();
        let actor = MediaPluginActor::new(pc_id);

        actor
            .update_local_playback(
                &bus,
                "VLC".into(),
                "Movie.mp4".into(),
                "file:///movie.mp4".into(),
                12000,
                120000,
                true,
            )
            .await;

        // Remote node sends acceptance for a bogus / foreign session ID
        actor
            .on_handoff_accepted_by_remote("foreign-session-uuid-999")
            .await
            .unwrap();

        // Current session must remain unchanged and still playing
        let session = actor.get_current_session().await.unwrap();
        assert!(
            session.is_playing,
            "Unmatched session ID must not pause active media"
        );
    }

    #[tokio::test]
    async fn test_websocket_media_update_and_state_query() {
        use futures_util::{SinkExt, StreamExt};
        let (bus, _rx) = EventBus::new(10, 10);
        let pc_id = DeviceId::new_random();
        let actor = MediaPluginActor::new(pc_id);

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let actor_clone = actor.clone();
        let bus_clone = bus.clone();

        tokio::spawn(async move {
            if let Ok((stream, _)) = listener.accept().await {
                if let Ok(mut ws_stream) = tokio_tungstenite::accept_async(stream).await {
                    if let Some(Ok(msg)) = ws_stream.next().await {
                        if let Ok(text) = msg.into_text() {
                            if let Ok(json_val) = serde_json::from_str::<serde_json::Value>(&text) {
                                actor_clone
                                    .update_local_playback(
                                        &bus_clone,
                                        json_val["source_app"].as_str().unwrap().to_string(),
                                        json_val["media_title"].as_str().unwrap().to_string(),
                                        json_val["media_url"].as_str().unwrap().to_string(),
                                        json_val["position_ms"].as_u64().unwrap(),
                                        json_val["duration_ms"].as_u64().unwrap(),
                                        json_val["is_playing"].as_bool().unwrap(),
                                    )
                                    .await;
                            }
                        }
                    }
                }
            }
        });

        // Connect client and send YouTube update
        let ws_url = format!("ws://127.0.0.1:{}/media", port);
        let (mut client_ws, _) = tokio_tungstenite::connect_async(&ws_url).await.unwrap();
        let update_json = serde_json::json!({
            "type": "NEXUS_MEDIA_STATE_UPDATE",
            "source_app": "YouTube (Chrome)",
            "media_title": "Interstellar - Main Theme (Official)",
            "media_url": "https://www.youtube.com/watch?v=UDVtMYqUAyw",
            "position_ms": 75000,
            "duration_ms": 300000,
            "is_playing": true
        });

        client_ws
            .send(tokio_tungstenite::tungstenite::Message::Text(
                update_json.to_string(),
            ))
            .await
            .unwrap();
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Verify session was updated accurately in actor
        let session = actor
            .get_current_session()
            .await
            .expect("Session must be present");
        assert_eq!(session.media_title, "Interstellar - Main Theme (Official)");
        assert_eq!(
            session.media_url,
            "https://www.youtube.com/watch?v=UDVtMYqUAyw"
        );
        assert_eq!(session.position_ms, 75000);
        assert_eq!(session.duration_ms, 300000);
        assert!(session.is_playing);
    }

    #[tokio::test]
    async fn test_proximity_departure_auto_pauses_media() {
        let (bus, _rx) = EventBus::new(10, 10);
        let pc_id = DeviceId::new_random();
        let actor = MediaPluginActor::new(pc_id);

        actor
            .update_local_playback(
                &bus,
                "YouTube (Chrome)".into(),
                "BBC Earth - Dynasties 4K".into(),
                "https://youtube.com/watch?v=earth".into(),
                45000,
                300000,
                true,
            )
            .await;

        let session = actor.get_current_session().await.unwrap();
        assert!(session.is_playing);

        // Spawn actor run loop in background
        let mut actor_clone = actor.clone();
        let bus_clone = bus.clone();
        let run_handle = tokio::spawn(async move {
            let _ = actor_clone.run(bus_clone).await;
        });

        // Give the spawned task time to initialize event subscription
        tokio::time::sleep(tokio::time::Duration::from_millis(150)).await;

        // Publish Proximity departure event (user walked away: 4.2 meters, is_near = false)
        let phone_id = DeviceId::new_random();
        bus.publish(NexusEvent::ProximityChanged {
            peer_id: phone_id,
            estimated_meters: 4.2,
            is_near: false,
        });

        // Wait with polling for auto-pause to take effect
        let mut paused = false;
        for _ in 0..20 {
            tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
            if let Some(session_after) = actor.get_current_session().await {
                if !session_after.is_playing {
                    paused = true;
                    break;
                }
            }
        }
        assert!(
            paused,
            "Proximity departure MUST auto-pause local playback"
        );

        run_handle.abort();
    }
}
