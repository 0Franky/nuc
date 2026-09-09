use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use nexus_types::{DeviceId, NexusError, NexusResult};
use rand::rngs::OsRng;
use x25519_dalek::{EphemeralSecret, PublicKey as X25519PublicKey, StaticSecret};

/// Persistent Cryptographic Identity of a Nexus Node
pub struct DeviceIdentity {
    pub device_id: DeviceId,
    pub signing_key: SigningKey,
    pub verifying_key: VerifyingKey,
    pub static_dh_secret: StaticSecret,
    pub static_dh_public: X25519PublicKey,
}

impl DeviceIdentity {
    /// Generates a new random cryptographic identity
    pub fn generate() -> Self {
        let signing_key = SigningKey::generate(&mut OsRng);
        let verifying_key = signing_key.verifying_key();
        let static_dh_secret = StaticSecret::random_from_rng(OsRng);
        let static_dh_public = X25519PublicKey::from(&static_dh_secret);

        let device_id = DeviceId::new_random();

        Self {
            device_id,
            signing_key,
            verifying_key,
            static_dh_secret,
            static_dh_public,
        }
    }

    /// Sign arbitrary bytes with Ed25519
    pub fn sign(&self, message: &[u8]) -> [u8; 64] {
        self.signing_key.sign(message).to_bytes()
    }

    /// Public key hex fingerprint
    pub fn fingerprint(&self) -> String {
        let hash = blake3::hash(self.verifying_key.as_bytes());
        hash.to_hex()[..16].to_string()
    }
}

/// Established Symmetric E2EE Cipher Channel between two paired peers
pub struct EncryptedChannel {
    send_cipher: ChaCha20Poly1305,
    recv_cipher: ChaCha20Poly1305,
    send_nonce: u64,
    recv_nonce: u64,
    pub remote_device_id: DeviceId,
}

impl EncryptedChannel {
    pub fn new(
        send_key: [u8; 32],
        recv_key: [u8; 32],
        remote_device_id: DeviceId,
    ) -> Self {
        Self {
            send_cipher: ChaCha20Poly1305::new(Key::from_slice(&send_key)),
            recv_cipher: ChaCha20Poly1305::new(Key::from_slice(&recv_key)),
            send_nonce: 0,
            recv_nonce: 0,
            remote_device_id,
        }
    }

    /// Encrypts plaintext with AEAD authentication and sequential nonce
    pub fn encrypt(&mut self, plaintext: &[u8]) -> NexusResult<Vec<u8>> {
        let mut nonce_bytes = [0u8; 12];
        nonce_bytes[4..12].copy_from_slice(&self.send_nonce.to_be_bytes());
        self.send_nonce += 1;

        let nonce = Nonce::from_slice(&nonce_bytes);
        let ciphertext = self
            .send_cipher
            .encrypt(nonce, plaintext)
            .map_err(|e| NexusError::Crypto(format!("Encryption failed: {}", e)))?;

        // Format: [12-byte Nonce] + [Ciphertext + 16-byte Poly1305 Tag]
        let mut result = Vec::with_capacity(12 + ciphertext.len());
        result.extend_from_slice(&nonce_bytes);
        result.extend_from_slice(&ciphertext);
        Ok(result)
    }

    /// Decrypts ciphertext and verifies Poly1305 authentication tag
    pub fn decrypt(&mut self, data: &[u8]) -> NexusResult<Vec<u8>> {
        if data.len() < 12 + 16 {
            return Err(NexusError::Crypto("Ciphertext too short".into()));
        }

        let nonce_bytes = &data[..12];
        let ciphertext = &data[12..];

        let nonce = Nonce::from_slice(nonce_bytes);
        let plaintext = self
            .recv_cipher
            .decrypt(nonce, ciphertext)
            .map_err(|e| NexusError::Crypto(format!("Decryption / MAC verification failed: {}", e)))?;

        self.recv_nonce += 1;
        Ok(plaintext)
    }
}

/// Noise_XX Handshake State Machine
pub struct NoiseHandshake {
    pub local_ephemeral: Option<EphemeralSecret>,
    pub local_ephemeral_pub: Option<X25519PublicKey>,
    pub remote_ephemeral_pub: Option<X25519PublicKey>,
    pub remote_static_pub: Option<X25519PublicKey>,
}

impl NoiseHandshake {
    pub fn new_initiator() -> (Self, [u8; 32]) {
        let ephemeral = EphemeralSecret::random_from_rng(OsRng);
        let ephemeral_pub = X25519PublicKey::from(&ephemeral);

        let handshake = Self {
            local_ephemeral: Some(ephemeral),
            local_ephemeral_pub: Some(ephemeral_pub),
            remote_ephemeral_pub: None,
            remote_static_pub: None,
        };

        (handshake, *ephemeral_pub.as_bytes())
    }

    /// Derives session keys from shared secret using BLAKE3 Key Derivation Function (KDF)
    pub fn derive_keys(shared_secret: &[u8]) -> ([u8; 32], [u8; 32]) {
        let mut kdf_context = blake3::Hasher::new_derive_key("nexus-noise-xx-session-keys");
        kdf_context.update(shared_secret);
        let root_key = kdf_context.finalize();

        let mut send_key = [0u8; 32];
        let mut recv_key = [0u8; 32];

        let mut kdf_send = blake3::Hasher::new_derive_key("nexus-initiator-to-responder");
        kdf_send.update(root_key.as_bytes());
        send_key.copy_from_slice(kdf_send.finalize().as_bytes());

        let mut kdf_recv = blake3::Hasher::new_derive_key("nexus-responder-to-initiator");
        kdf_recv.update(root_key.as_bytes());
        recv_key.copy_from_slice(kdf_recv.finalize().as_bytes());

        (send_key, recv_key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signature, Verifier};

    #[test]
    fn test_device_identity_generation_and_signing() {
        let identity = DeviceIdentity::generate();
        let message = b"Nexus Authenticated Event";

        let signature_bytes = identity.sign(message);
        let signature = Signature::from_bytes(&signature_bytes);

        assert!(identity.verifying_key.verify(message, &signature).is_ok());
        assert!(identity.verifying_key.verify(b"Tampered message", &signature).is_err());
    }

    #[test]
    fn test_e2ee_channel_encryption_decryption() {
        let alice_id = DeviceId::new_random();
        let bob_id = DeviceId::new_random();

        let shared_secret = b"sample_32_byte_shared_secret_123";
        let (alice_send_key, alice_recv_key) = NoiseHandshake::derive_keys(shared_secret);

        // Alice sends with send_key, Bob receives with alice_send_key
        let mut alice_channel = EncryptedChannel::new(alice_send_key, alice_recv_key, bob_id);
        let mut bob_channel = EncryptedChannel::new(alice_recv_key, alice_send_key, alice_id);

        let secret_payload = b"Continuous Video Streaming at 14:22 on YouTube";

        let encrypted = alice_channel.encrypt(secret_payload).expect("Encryption failed");
        assert_ne!(encrypted, secret_payload);

        let decrypted = bob_channel.decrypt(&encrypted).expect("Decryption failed");
        assert_eq!(decrypted, secret_payload);
    }

    #[test]
    fn test_tampered_ciphertext_rejection() {
        let alice_id = DeviceId::new_random();
        let bob_id = DeviceId::new_random();

        let (k1, k2) = NoiseHandshake::derive_keys(b"random_secret_string_for_testing");
        let mut alice = EncryptedChannel::new(k1, k2, bob_id);
        let mut bob = EncryptedChannel::new(k2, k1, alice_id);

        let mut encrypted = alice.encrypt(b"Original message").unwrap();
        // Tamper 1 byte in the ciphertext payload
        let last_idx = encrypted.len() - 1;
        encrypted[last_idx] ^= 0xFF;

        let result = bob.decrypt(&encrypted);
        assert!(result.is_err(), "Tampered ciphertext must be rejected by Poly1305 MAC");
    }

    #[test]
    fn test_truncated_and_corrupted_payload_rejection() {
        let bob_id = DeviceId::new_random();
        let (k1, k2) = NoiseHandshake::derive_keys(b"test_secret_for_truncation");
        let mut bob = EncryptedChannel::new(k2, k1, bob_id);

        // Sub-28 bytes inputs (impossible to contain 12B nonce + 16B Poly1305 tag)
        assert!(bob.decrypt(&[]).is_err());
        assert!(bob.decrypt(&[0u8; 5]).is_err());
        assert!(bob.decrypt(&[0u8; 27]).is_err());
    }

    #[test]
    fn test_empty_and_large_payload_boundaries() {
        let alice_id = DeviceId::new_random();
        let bob_id = DeviceId::new_random();

        let (k1, k2) = NoiseHandshake::derive_keys(b"test_secret_boundary_cases");
        let mut alice = EncryptedChannel::new(k1, k2, bob_id);
        let mut bob = EncryptedChannel::new(k2, k1, alice_id);

        // 1. Empty payload boundary
        let empty_enc = alice.encrypt(b"").expect("Empty encryption should succeed");
        let empty_dec = bob.decrypt(&empty_enc).expect("Empty decryption should succeed");
        assert_eq!(empty_dec, b"");

        // 2. Large 256KB video/audio payload boundary
        let large_payload = vec![0xAB; 256 * 1024];
        let large_enc = alice.encrypt(&large_payload).expect("Large encryption should succeed");
        let large_dec = bob.decrypt(&large_enc).expect("Large decryption should succeed");
        assert_eq!(large_dec, large_payload);
    }

    #[test]
    fn test_nonce_isolation_and_unrelated_key_rejection() {
        let alice_id = DeviceId::new_random();
        let bob_id = DeviceId::new_random();

        let (k1, k2) = NoiseHandshake::derive_keys(b"secret_key_pair_a");
        let (k3, k4) = NoiseHandshake::derive_keys(b"secret_key_pair_b_unrelated");

        let mut alice = EncryptedChannel::new(k1, k2, bob_id);
        let mut eve = EncryptedChannel::new(k3, k4, alice_id);

        let msg = b"Super sensitive clipboard OTP code 993182";
        let encrypted = alice.encrypt(msg).unwrap();

        // Eve trying to decrypt Alice's message with an unrelated key must strictly fail
        let eve_result = eve.decrypt(&encrypted);
        assert!(eve_result.is_err(), "Eve with wrong key must not decrypt message");
    }
}
