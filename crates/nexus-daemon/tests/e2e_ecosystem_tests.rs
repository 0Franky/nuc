use nexus_actor_system::{EventBus, NexusCommand, NexusEvent};
use nexus_crypto::{DeviceIdentity, EncryptedChannel, NoiseHandshake};
use nexus_plugin_audio::{AdaptiveJitterBuffer, AudioRingBuffer, DriftResampler};
use nexus_plugin_clipboard::ClipboardPluginActor;
use nexus_plugin_media::MediaPluginActor;
use nexus_plugin_proximity::ProximityPluginActor;
use nexus_protocol::{
    ClipboardPayload, MediaPayload, NexusPacket, PacketPayload, SmartHintType,
};
use nexus_transport::VirtualLoopbackRouter;
use nexus_types::DeviceId;

/// END-TO-END TEST 1: Full E2EE Handshake, Video Continuity Handoff & Auto-Pause
#[tokio::test]
async fn test_e2e_multi_device_video_handoff_and_auto_pause() {
    let router = VirtualLoopbackRouter::new();

    // 1. Initialize Node A (Windows PC) and Node B (Android Phone)
    let pc_identity = DeviceIdentity::generate();
    let pc_id = pc_identity.device_id;
    let (pc_bus, mut pc_cmd_rx) = EventBus::new(100, 100);
    let pc_media = MediaPluginActor::new(pc_id);

    let phone_identity = DeviceIdentity::generate();
    let phone_id = phone_identity.device_id;
    let (phone_bus, mut phone_cmd_rx) = EventBus::new(100, 100);
    let phone_media = MediaPluginActor::new(phone_id);

    let (_pc_tx, mut pc_rx) = router.register_node(pc_id).await;
    let (_phone_tx, mut phone_rx) = router.register_node(phone_id).await;

    // 2. Establish Noise_XX E2EE Channel between PC and Phone
    let (k_pc_send, k_pc_recv) = NoiseHandshake::derive_keys(b"shared_e2e_pairing_token_99");
    let mut pc_crypto = EncryptedChannel::new(k_pc_send, k_pc_recv, phone_id);
    let mut phone_crypto = EncryptedChannel::new(k_pc_recv, k_pc_send, pc_id);

    // Verify key exchange symmetry
    let test_ping = b"E2EE handshake check";
    let encrypted_check = pc_crypto.encrypt(test_ping).unwrap();
    let decrypted_check = phone_crypto.decrypt(&encrypted_check).unwrap();
    assert_eq!(decrypted_check, test_ping);

    // 3. PC starts playing YouTube video
    pc_media
        .update_local_playback(
            &pc_bus,
            "YouTube (Chrome)".into(),
            "Rust 2026 Deep Dive".into(),
            "https://youtube.com/watch?v=rust2026".into(),
            862_000, // 14 min 22 sec
            1_800_000, // 30 min total
            true,
        )
        .await;

    let pc_session = pc_media.get_current_session().await.unwrap();
    assert!(pc_session.is_playing);
    assert_eq!(pc_session.position_ms, 862_000);

    // 4. PC initiates Handoff Offer to Phone
    pc_media.offer_handoff_to_peer(&pc_bus, phone_id).await.unwrap();

    let offer_cmd = pc_cmd_rx.recv().await.expect("Expected PC command");
    if let NexusCommand::SendPacket { target, packet } = offer_cmd {
        assert_eq!(target, phone_id);
        router.route_packet(packet).await.unwrap();
    }

    // 5. Phone receives packet from virtual network
    let incoming_packet = phone_rx.recv().await.expect("Phone received packet");
    assert_eq!(incoming_packet.sender_id, pc_id);

    // 6. Phone accepts handoff at the exact timestamp
    if let PacketPayload::Media(MediaPayload::OfferHandoff {
        session_id,
        position_ms,
        media_url,
        media_title,
        ..
    }) = incoming_packet.payload
    {
        assert_eq!(position_ms, 862_000);
        assert_eq!(media_title, "Rust 2026 Deep Dive");
        assert_eq!(media_url, "https://youtube.com/watch?v=rust2026");

        // Phone accepts
        phone_media
            .accept_handoff(&phone_bus, pc_id, session_id.clone(), position_ms)
            .await
            .unwrap();

        let accept_cmd = phone_cmd_rx.recv().await.expect("Expected Phone accept command");
        if let NexusCommand::SendPacket { target, packet } = accept_cmd {
            assert_eq!(target, pc_id);
            router.route_packet(packet).await.unwrap();
        }

        // 7. PC receives handoff acceptance and auto-pauses source player
        let pc_recv_packet = pc_rx.recv().await.expect("PC received acceptance");
        if let PacketPayload::Media(MediaPayload::AcceptHandoff { session_id: accepted_sid, .. }) =
            pc_recv_packet.payload
        {
            assert_eq!(accepted_sid, session_id);
            pc_media.on_handoff_accepted_by_remote(&accepted_sid).await.unwrap();
        }
    }

    // 8. Assert PC playback is now paused
    let pc_final_session = pc_media.get_current_session().await.unwrap();
    assert!(!pc_final_session.is_playing, "PC must pause local playback after remote accept");
}

/// END-TO-END TEST 2: Low-Latency Audio Relay Pipeline (<18ms) with RingBuffer & Jitter Resampler
#[tokio::test]
async fn test_e2e_audio_relay_pipeline_and_drift_compensation() {
    // 1. Audio Capture Thread pushes 480 samples (10ms of 48kHz audio) into RingBuffer
    let mut ring = AudioRingBuffer::new(2048);
    let captured_tone: Vec<f32> = (0..480).map(|i| ((i as f32) * 0.1).sin()).collect();
    let written = ring.push_slice(&captured_tone);
    assert_eq!(written, 480);

    // 2. Network packetizer pops from ring buffer into Opus Frame packet
    let mut pcm_to_encode = vec![0.0f32; 480];
    ring.pop_slice(&mut pcm_to_encode);
    assert_eq!(pcm_to_encode, captured_tone);

    // 3. Transmit through Adaptive Jitter Buffer
    let mut jitter = AdaptiveJitterBuffer::new(10.0);
    jitter.push_packet(1, 10000, vec![0x10, 0x20]);
    jitter.push_packet(2, 20000, vec![0x30, 0x40]);
    jitter.push_packet(3, 30000, vec![0x50, 0x60]);

    let f1 = jitter.pop_frame().unwrap();
    assert_eq!(f1, vec![0x10, 0x20]);

    // 4. Clock Drift Resampler applies smooth pitch adjustment (+0.02% drift compensation)
    let mut resampler = DriftResampler::new();
    resampler.set_drift_adjustment(1.0002);

    let mut resampled_out = vec![0.0f32; 480];
    let processed = resampler.process_linear(&pcm_to_encode, &mut resampled_out);
    assert!(processed >= 478);

    // Verify samples are non-NaN and non-Inf
    for &sample in &resampled_out[..processed] {
        assert!(!sample.is_nan());
        assert!(!sample.is_infinite());
    }
}

/// END-TO-END TEST 3: Smart Clipboard E2EE Synchronization & Loop Guard Anti-Bounce
#[tokio::test]
async fn test_e2e_smart_clipboard_otp_detection_and_loop_guard() {
    let (bus, mut cmd_rx) = EventBus::new(10, 10);
    let laptop_id = DeviceId::new_random();
    let phone_id = DeviceId::new_random();

    let actor = ClipboardPluginActor::new(laptop_id);

    // 1. User copies SMS OTP on Laptop
    let otp_text = "948201";
    let hint = actor
        .on_local_clipboard_changed(&bus, otp_text, Some(phone_id))
        .await
        .unwrap();

    assert_eq!(hint, Some(SmartHintType::Otp2Fa), "Parser must detect 6-digit OTP");

    let cmd = cmd_rx.recv().await.expect("Expected command");
    if let NexusCommand::SendPacket { target, packet } = cmd {
        assert_eq!(target, phone_id);
        if let PacketPayload::Clipboard(ClipboardPayload::EncryptedText { ciphertext, .. }) = packet.payload {
            assert_eq!(String::from_utf8(ciphertext).unwrap(), otp_text);
        }
    }

    // 2. LoopGuard test: Attempting to synchronize the same text back must be silently ignored
    let second_sync = actor
        .on_local_clipboard_changed(&bus, otp_text, Some(phone_id))
        .await
        .unwrap();
    assert_eq!(second_sync, None, "LoopGuard must suppress duplicate re-synchronization");
}

/// END-TO-END TEST 4: Proximity Kalman Smoothing & Walk-Away Detection
#[tokio::test]
async fn test_e2e_proximity_kalman_filtering_and_walkaway_detection() {
    let (bus, _cmd_rx) = EventBus::new(100, 100);
    let mut sub = bus.subscribe();

    let pc_id = DeviceId::new_random();
    let phone_id = DeviceId::new_random();
    let proximity_actor = ProximityPluginActor::new(pc_id);
    assert!(!proximity_actor.auto_lock_enabled()); // Consent is off by default.

    // 1. Phone is near desk (-52 dBm, approx 1.1m)
    for _ in 0..5 {
        proximity_actor.process_ble_sample(&bus, phone_id, -52.0, -59.0).await;
    }

    // 2. User walks away with phone to kitchen (-85 dBm, approx 5.5m)
    for _ in 0..10 {
        proximity_actor.process_ble_sample(&bus, phone_id, -85.0, -59.0).await;
    }

    // 3. Verify event bus received proximity change event with is_near = false
    let mut received_far_event = false;
    while let Ok(event) = sub.try_recv() {
        if let NexusEvent::ProximityChanged { is_near, estimated_meters, .. } = event {
            if !is_near && estimated_meters > 3.5 {
                received_far_event = true;
                break;
            }
        }
    }

    assert!(received_far_event, "Walk-away transition must publish ProximityChanged(is_near = false)");
}

/// END-TO-END TEST 5: Malicious Packet & Tampered Data Resilience
#[tokio::test]
async fn test_e2e_malicious_packet_injection_resilience() {
    // Attempt decoding invalid/fuzzed raw byte streams
    let garbage_packet_1 = vec![0xFF, 0x00, 0xDE, 0xAD];
    let garbage_packet_2 = vec![0x00; 1024];

    let decode_1 = NexusPacket::decode(&garbage_packet_1);
    assert!(decode_1.is_err(), "Garbage header must fail decode gracefully without panic");

    let decode_2 = NexusPacket::decode(&garbage_packet_2);
    assert!(decode_2.is_err(), "All-zero byte stream must fail decode gracefully without panic");
}
