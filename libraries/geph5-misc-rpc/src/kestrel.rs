//! Kestrel: per-device credentials for a private, broker-less exit.
//!
//! Each device holds its own ed25519 signing key. On every connection the
//! client signs its fresh X25519 hello together with a timestamp, so a
//! captured credential cannot be replayed: the exit would answer with keys
//! only the original client can derive.

use std::time::{SystemTime, UNIX_EPOCH};

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use stdcode::StdcodeSerializeExt;

use crate::exit::ClientCryptHello;

/// How far a device clock may drift from the exit's clock.
pub const MAX_CLOCK_SKEW_SECS: u64 = 300;

/// A device's identity, as stored in the client config.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct KestrelDevice {
    /// The device name the exit knows this key by.
    pub name: String,
    /// The 32-byte ed25519 secret key, hex-encoded.
    pub secret: String,
}

impl KestrelDevice {
    /// Generates a fresh device identity.
    pub fn generate(name: &str) -> Self {
        let key = SigningKey::from_bytes(&rand_secret());
        Self {
            name: name.to_string(),
            secret: hex::encode(key.to_bytes()),
        }
    }

    pub fn signing_key(&self) -> anyhow::Result<SigningKey> {
        let bytes: [u8; 32] = hex::decode(self.secret.trim())?
            .try_into()
            .map_err(|_| anyhow::anyhow!("device secret must be 32 bytes"))?;
        Ok(SigningKey::from_bytes(&bytes))
    }

    pub fn public_key_hex(&self) -> anyhow::Result<String> {
        Ok(hex::encode(self.signing_key()?.verifying_key().as_bytes()))
    }
}

fn rand_secret() -> [u8; 32] {
    let mut out = [0u8; 32];
    getrandom::getrandom(&mut out).expect("system RNG unavailable");
    out
}

/// The credential a device sends in `ClientHello::credentials`.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct DeviceCredential {
    pub device: String,
    pub timestamp: u64,
    pub signature: Signature,
}

fn signed_message(device: &str, timestamp: u64, crypt_hello: &ClientCryptHello) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new_derive_key("kestrel device auth v1");
    hasher.update(&(device, timestamp, crypt_hello).stdcode());
    *hasher.finalize().as_bytes()
}

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

impl DeviceCredential {
    pub fn sign(device: &KestrelDevice, crypt_hello: &ClientCryptHello) -> anyhow::Result<Self> {
        let key = device.signing_key()?;
        let timestamp = now_secs();
        let signature = key.sign(&signed_message(&device.name, timestamp, crypt_hello));
        Ok(Self {
            device: device.name.clone(),
            timestamp,
            signature,
        })
    }

    /// Checks the signature and freshness against the device's public key.
    pub fn verify(
        &self,
        pubkey: &VerifyingKey,
        crypt_hello: &ClientCryptHello,
        now: u64,
    ) -> anyhow::Result<()> {
        if self.timestamp.abs_diff(now) > MAX_CLOCK_SKEW_SECS {
            anyhow::bail!("credential timestamp outside the allowed window");
        }
        pubkey
            .verify(
                &signed_message(&self.device, self.timestamp, crypt_hello),
                &self.signature,
            )
            .map_err(|_| anyhow::anyhow!("bad device signature"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hello() -> ClientCryptHello {
        ClientCryptHello::X25519(x25519_dalek::PublicKey::from(rand_secret()))
    }

    #[test]
    fn valid_credential_verifies() {
        let dev = KestrelDevice::generate("macbook");
        let h = hello();
        let cred = DeviceCredential::sign(&dev, &h).unwrap();
        let pk = dev.signing_key().unwrap().verifying_key();
        cred.verify(&pk, &h, now_secs()).unwrap();
    }

    #[test]
    fn credential_is_bound_to_the_hello() {
        let dev = KestrelDevice::generate("macbook");
        let cred = DeviceCredential::sign(&dev, &hello()).unwrap();
        let pk = dev.signing_key().unwrap().verifying_key();
        assert!(cred.verify(&pk, &hello(), now_secs()).is_err());
    }

    #[test]
    fn other_device_key_is_rejected() {
        let dev = KestrelDevice::generate("macbook");
        let other = KestrelDevice::generate("macbook");
        let h = hello();
        let cred = DeviceCredential::sign(&dev, &h).unwrap();
        let pk = other.signing_key().unwrap().verifying_key();
        assert!(cred.verify(&pk, &h, now_secs()).is_err());
    }

    #[test]
    fn stale_credential_is_rejected() {
        let dev = KestrelDevice::generate("macbook");
        let h = hello();
        let cred = DeviceCredential::sign(&dev, &h).unwrap();
        let pk = dev.signing_key().unwrap().verifying_key();
        assert!(cred.verify(&pk, &h, now_secs() + 3600).is_err());
    }
}
