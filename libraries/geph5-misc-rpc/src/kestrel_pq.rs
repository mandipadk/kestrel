//! Kestrel: a quantum-safe handshake. The session keys come from both an
//! X25519 exchange and ML-KEM-768 (FIPS 203), so traffic recorded today stays
//! private even if X25519 is broken later ("harvest now, decrypt later"), and
//! is no weaker than X25519 if ML-KEM ever is.
//!
//! The device puts its ML-KEM encapsulation key in its hello, which it signs
//! with its device key; the exit signs its answer (with the ciphertext) over
//! the whole hello. Neither half can be swapped or stripped in transit.

use ml_kem::{Decapsulate, Encapsulate, EncapsulationKey, Kem, KeyExport, MlKem768, array::Array};

/// The device's half of the handshake, kept until the exit answers.
pub struct DeviceKem {
    decapsulation_key: ml_kem::ml_kem_768::DecapsulationKey,
}

/// Byte lengths of ML-KEM-768's encapsulation key and ciphertext.
pub const EK_LEN: usize = 1184;
pub const CT_LEN: usize = 1088;

impl DeviceKem {
    /// A fresh key pair and the encapsulation key to send.
    pub fn generate() -> (Self, Vec<u8>) {
        let (dk, ek) = MlKem768::generate_keypair();
        (
            Self {
                decapsulation_key: dk,
            },
            ek.to_bytes().to_vec(),
        )
    }

    /// The shared secret from the exit's ciphertext.
    pub fn finish(&self, ciphertext: &[u8]) -> anyhow::Result<[u8; 32]> {
        anyhow::ensure!(
            ciphertext.len() == CT_LEN,
            "ML-KEM ciphertext has the wrong length"
        );
        let ss = self
            .decapsulation_key
            .decapsulate_slice(ciphertext)
            .map_err(|_| anyhow::anyhow!("ML-KEM ciphertext could not be read"))?;
        Ok(ss.into())
    }
}

/// The exit's half: encapsulate to the device's key. Returns the ciphertext
/// to send back and the shared secret.
pub fn exit_encapsulate(encapsulation_key: &[u8]) -> anyhow::Result<(Vec<u8>, [u8; 32])> {
    anyhow::ensure!(
        encapsulation_key.len() == EK_LEN,
        "ML-KEM encapsulation key has the wrong length"
    );
    let key = Array::try_from(encapsulation_key)
        .map_err(|_| anyhow::anyhow!("ML-KEM encapsulation key has the wrong length"))?;
    let ek = EncapsulationKey::<MlKem768>::new(&key)
        .map_err(|_| anyhow::anyhow!("not a valid ML-KEM encapsulation key"))?;
    let (ct, ss) = ek.encapsulate();
    Ok((ct.to_vec(), ss.into()))
}

/// The session keys (device-to-exit, exit-to-device) from both secrets.
pub fn session_keys(x25519: &[u8; 32], ml_kem: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let mut both = [0u8; 64];
    both[..32].copy_from_slice(x25519);
    both[32..].copy_from_slice(ml_kem);
    (
        blake3::derive_key("kestrel x25519+mlkem768 c2e", &both),
        blake3::derive_key("kestrel x25519+mlkem768 e2c", &both),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_and_exit_agree() {
        let (device, ek) = DeviceKem::generate();
        assert_eq!(ek.len(), EK_LEN);
        let (ct, exit_ss) = exit_encapsulate(&ek).unwrap();
        assert_eq!(ct.len(), CT_LEN);
        assert_eq!(device.finish(&ct).unwrap(), exit_ss);
    }

    #[test]
    fn a_changed_ciphertext_gives_a_different_secret() {
        // ML-KEM rejects implicitly: a tampered ciphertext decapsulates to an
        // unrelated secret, so the keys disagree and the session fails
        let (device, ek) = DeviceKem::generate();
        let (mut ct, exit_ss) = exit_encapsulate(&ek).unwrap();
        ct[100] ^= 1;
        assert_ne!(device.finish(&ct).unwrap(), exit_ss);
    }

    #[test]
    fn wrong_lengths_are_refused() {
        let (device, ek) = DeviceKem::generate();
        assert!(exit_encapsulate(&ek[..EK_LEN - 1]).is_err());
        assert!(exit_encapsulate(&[]).is_err());
        assert!(device.finish(&[0u8; CT_LEN - 1]).is_err());
    }

    #[test]
    fn keys_depend_on_both_secrets() {
        let a = [1u8; 32];
        let b = [2u8; 32];
        let (c2e, e2c) = session_keys(&a, &b);
        assert_ne!(c2e, e2c);
        assert_ne!(session_keys(&a, &a).0, c2e);
        assert_ne!(session_keys(&b, &b).0, c2e);
    }
}
