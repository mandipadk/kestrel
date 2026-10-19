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
    /// Reach the exit over sosistab3 instead of plain TCP (see [`stealth_cookie`]).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stealth: bool,
    /// The tunnel's MTU on the system side (the apps use 1450). The engine's
    /// IP stack never sends the system a bigger packet: Apple's packet flow
    /// drops those. None keeps the engine's per-platform default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vpn_mtu: Option<u16>,
    /// Tests only: handshake like an app from before the quantum-safe one
    /// (X25519 alone), to prove exits still serve, or refuse, such apps.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub classical_handshake: bool,
    /// All of the owner's exits this device may use. Empty: only the one in
    /// `exit_constraint` (devices set up before there were two).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub exits: Vec<KestrelExit>,
    /// The city of the exit to stay on. None: automatic (the fastest exit at
    /// connect time, and whichever answers if it stops).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_choice: Option<String>,
    /// How to reach the exits: None (automatic: direct, and the disguised
    /// address too when direct doesn't answer), "direct" or "disguised".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
}

/// One of the owner's exits, as a device knows it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct KestrelExit {
    /// "host:port"
    pub endpoint: String,
    /// The exit's ed25519 public key, hex-encoded.
    pub pubkey: String,
    /// Shown in the apps, e.g. "Chicago".
    pub city: String,
    /// The exit's disguised address (`wss://host/path`): a WebSocket on the
    /// owner's Cloudflare zone that hands the bytes to this exit, for networks
    /// that block the exit's own address or random-looking traffic.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disguise: Option<String>,
}

impl KestrelDevice {
    /// Generates a fresh device identity.
    pub fn generate(name: &str) -> Self {
        let key = SigningKey::from_bytes(&rand_secret());
        Self {
            name: name.to_string(),
            secret: hex::encode(key.to_bytes()),
            stealth: true,
            vpn_mtu: None,
            classical_handshake: false,
            exits: Vec::new(),
            exit_choice: None,
            link: None,
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

/// The sosistab3 cookie for a stealth link to the exit with this public key.
///
/// Only devices hold the exit's public key (it is never published: there is
/// no broker), so a prober cannot complete the obfuscated handshake and gets
/// nothing back, while the link itself looks like random bytes on the wire.
pub fn stealth_cookie(exit_pubkey: &[u8; 32]) -> String {
    hex::encode(blake3::derive_key("kestrel stealth cookie v1", exit_pubkey))
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
    fn stealth_cookie_depends_on_the_exit() {
        let a = stealth_cookie(&[1; 32]);
        assert_eq!(a, stealth_cookie(&[1; 32]));
        assert_ne!(a, stealth_cookie(&[2; 32]));
        assert_eq!(a.len(), 64);
    }

    #[test]
    fn old_configs_without_stealth_still_parse() {
        let dev: KestrelDevice =
            serde_json::from_str(r#"{"name":"macbook","secret":"00"}"#).unwrap();
        assert!(!dev.stealth);
        assert!(KestrelDevice::generate("new").stealth);
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
