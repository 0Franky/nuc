use crate::DeviceIdentity;
use ed25519_dalek::SigningKey;
use nexus_types::DeviceId;
use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};
use x25519_dalek::{PublicKey, StaticSecret};

impl DeviceIdentity {
    pub fn config_directory() -> io::Result<PathBuf> {
        if let Some(path) = std::env::var_os("NEXUS_CONFIG_DIR") {
            return Ok(PathBuf::from(path));
        }
        #[cfg(target_os = "windows")]
        let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
        #[cfg(not(target_os = "windows"))]
        let base = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".config")));
        base.map(|p| p.join("nexus")).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "No configuration directory; set NEXUS_CONFIG_DIR",
            )
        })
    }

    pub fn device_name(default: String) -> String {
        Self::config_directory()
            .ok()
            .and_then(|dir| fs::read_to_string(dir.join("device-name.txt")).ok())
            .filter(|name| !name.trim().is_empty())
            .map(|name| name.trim().to_string())
            .unwrap_or(default)
    }

    pub fn save_device_name(name: &str) -> io::Result<()> {
        let directory = Self::config_directory()?;
        fs::create_dir_all(&directory)?;
        let temporary = directory.join(format!(".device-name-{}.tmp", DeviceId::new_random()));
        fs::write(&temporary, name.trim())?;
        let result = fs::rename(&temporary, directory.join("device-name.txt"));
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result
    }

    pub fn load_or_create() -> io::Result<Self> {
        Self::load_or_create_at(&Self::config_directory()?.join("identity.bin"))
    }

    pub fn load_or_create_at(path: &Path) -> io::Result<Self> {
        match fs::read(path) {
            Ok(bytes) => return Self::decode_identity(&bytes),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let parent = path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "Missing identity directory")
        })?;
        fs::create_dir_all(parent)?;
        let identity = Self::generate();
        let temporary = parent.join(format!(".identity-{}.tmp", identity.device_id));
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        let mut bytes = Vec::with_capacity(84);
        bytes.extend_from_slice(b"NXI1");
        bytes.extend_from_slice(identity.device_id.as_bytes());
        bytes.extend_from_slice(&identity.signing_key.to_bytes());
        bytes.extend_from_slice(&identity.static_dh_secret.to_bytes());
        let result = (|| {
            file.write_all(&bytes)?;
            file.sync_all()?;
            drop(file);
            // Publish a complete file without replacing another process's identity.
            match fs::hard_link(&temporary, path) {
                Ok(()) => Ok(identity),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    Self::decode_identity(&fs::read(path)?)
                }
                Err(e) => Err(e),
            }
        })();
        let _ = fs::remove_file(temporary);
        result
    }

    fn decode_identity(bytes: &[u8]) -> io::Result<Self> {
        if bytes.len() != 84 || &bytes[..4] != b"NXI1" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid Nexus identity; refusing to replace it",
            ));
        }
        let signing_key = SigningKey::from_bytes(bytes[20..52].try_into().unwrap());
        let static_dh_secret = StaticSecret::from(<[u8; 32]>::try_from(&bytes[52..84]).unwrap());
        Ok(Self {
            device_id: DeviceId::from_bytes(bytes[4..20].try_into().unwrap()),
            verifying_key: signing_key.verifying_key(),
            static_dh_public: PublicKey::from(&static_dh_secret),
            signing_key,
            static_dh_secret,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_survives_restart_and_rejects_corruption() {
        let dir =
            std::env::temp_dir().join(format!("nexus-identity-test-{}", DeviceId::new_random()));
        let path = dir.join("identity.bin");
        let first = DeviceIdentity::load_or_create_at(&path).unwrap();
        let second = DeviceIdentity::load_or_create_at(&path).unwrap();
        assert_eq!(first.device_id, second.device_id);
        assert_eq!(first.fingerprint(), second.fingerprint());
        assert_eq!(
            first.static_dh_public.as_bytes(),
            second.static_dh_public.as_bytes()
        );
        fs::write(&path, b"broken").unwrap();
        assert!(DeviceIdentity::load_or_create_at(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"broken");
        fs::remove_file(path).unwrap();
        fs::remove_dir(dir).unwrap();
    }
}
