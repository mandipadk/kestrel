//! kestrelctl: add, list and revoke the devices allowed to use this exit, and
//! write the client config a new device needs.

use std::{
    fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

use anyhow::Context;
use clap::{Parser, Subcommand};
use ed25519_dalek::SigningKey;
use geph5_misc_rpc::kestrel::KestrelDevice;
use serde::{Deserialize, Serialize};

#[derive(Parser)]
#[command(about = "Manage the devices allowed to use this Kestrel exit")]
struct Args {
    /// The device list the exit reads.
    #[arg(long, default_value = "/var/lib/kestrel/devices.json")]
    devices: PathBuf,
    /// The exit's signing secret, used to tell clients the exit's public key.
    #[arg(long, default_value = "/var/lib/kestrel/signing.key")]
    signing_secret: PathBuf,
    /// The address devices dial, host:port.
    #[arg(long, env = "KESTREL_ENDPOINT", default_value = "92.5.139.56:443")]
    endpoint: String,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create a key for a new device and write its client config.
    Add {
        name: String,
        /// Where to write the client config (mode 600).
        #[arg(long)]
        out: PathBuf,
    },
    /// List devices.
    List {
        #[arg(long)]
        json: bool,
    },
    /// Revoke a device; it is refused from its next connection on.
    Revoke { name: String },
    /// Replace a device's key (revokes the old one) and write a new config.
    Rotate {
        name: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Print the exit's public key.
    Pubkey,
    /// Turn Shield (ad, tracker and malware blocking) on or off for a device.
    Shield { name: String, state: OnOff },
    /// Never block this domain (or its subdomains) for any device.
    Allow { domain: String },
    /// Take a domain off the allow list.
    Unallow { domain: String },
    /// Print the allow list.
    Allowed,
}

#[derive(Clone, Copy, clap::ValueEnum)]
enum OnOff {
    On,
    Off,
}

#[derive(Serialize, Deserialize, Default)]
struct DeviceFile {
    #[serde(default)]
    devices: Vec<DeviceEntry>,
}

#[derive(Serialize, Deserialize, Clone)]
struct DeviceEntry {
    name: String,
    pubkey: String,
    #[serde(default)]
    added: String,
    #[serde(default)]
    revoked: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    shield: Option<bool>,
    /// When a rotated key was replaced. Kept so the exit can tell the owner
    /// if the old key is ever used.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    replaced: Option<String>,
}

fn load(path: &Path) -> anyhow::Result<DeviceFile> {
    match fs::read(path) {
        Ok(raw) => Ok(serde_json::from_slice(&raw)?),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(DeviceFile::default()),
        Err(e) => Err(e.into()),
    }
}

fn save(path: &Path, file: &DeviceFile) -> anyhow::Result<()> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, serde_json::to_vec_pretty(file)?)?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o640))?;
    fs::rename(&tmp, path)?;
    Ok(())
}

fn exit_pubkey(path: &Path) -> anyhow::Result<String> {
    let bytes: [u8; 32] = fs::read(path)
        .with_context(|| format!("cannot read {}", path.display()))?
        .try_into()
        .map_err(|_| anyhow::anyhow!("signing secret must be 32 bytes"))?;
    Ok(hex::encode(
        SigningKey::from_bytes(&bytes).verifying_key().as_bytes(),
    ))
}

/// Revokes every key of this device. False if there is no such device.
fn revoke(file: &mut DeviceFile, name: &str) -> bool {
    let mut found = false;
    for d in file.devices.iter_mut().filter(|d| d.name == name) {
        d.revoked = true;
        found = true;
    }
    found
}

/// Marks every live key of this device as replaced (revoked, but kept).
fn retire(file: &mut DeviceFile, name: &str) {
    // keep only the latest replaced key per device, so the file stays small
    file.devices.retain(|d| !(d.name == name && d.revoked));
    for d in file.devices.iter_mut().filter(|d| d.name == name) {
        d.revoked = true;
        d.replaced = Some(today());
    }
}

fn allow_path(devices: &Path) -> PathBuf {
    devices.with_file_name("shield-allow.txt")
}

fn read_allow(path: &Path) -> Vec<String> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect()
}

fn valid_domain(domain: &str) -> anyhow::Result<String> {
    let d = domain.trim().trim_end_matches('.').to_ascii_lowercase();
    anyhow::ensure!(
        !d.is_empty()
            && d.len() <= 253
            && d.contains('.')
            && d.split('.').all(|l| !l.is_empty()
                && l.len() <= 63
                && l.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')),
        "not a domain name: {domain}"
    );
    Ok(d)
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 32
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn today() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}

fn client_config(args: &Args, device: &KestrelDevice) -> anyhow::Result<String> {
    let cfg = serde_json::json!({
        "socks5_listen": "127.0.0.1:9909",
        "http_proxy_listen": "127.0.0.1:9910",
        "pac_listen": "127.0.0.1:9911",
        "control_listen": "127.0.0.1:9809",
        "exit_constraint": { "direct": format!("{}/{}", args.endpoint, exit_pubkey(&args.signing_secret)?) },
        "allow_direct": false,
        "cache": null,
        "broker": null,
        "broker_keys": null,
        "spoof_dns": false,
        "passthrough_china": false,
        "allow_lan": true,
        "task_limit": null,
        "kestrel_device": device,
    });
    Ok(format!(
        "# Kestrel client config for \"{}\". Keep this file private: it is this device's key.\n{}",
        device.name,
        serde_yaml::to_string(&cfg)?
    ))
}

fn write_private(path: &Path, contents: &str) -> anyhow::Result<()> {
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(contents.as_bytes())?;
    Ok(())
}

fn enroll(
    args: &Args,
    file: &mut DeviceFile,
    name: &str,
    shield: Option<bool>,
    out: &Path,
) -> anyhow::Result<()> {
    let device = KestrelDevice::generate(name);
    let config = client_config(args, &device)?;
    file.devices.push(DeviceEntry {
        name: name.to_string(),
        pubkey: device.public_key_hex()?,
        added: today(),
        revoked: false,
        shield,
        replaced: None,
    });
    write_private(out, &config)?;
    save(&args.devices, file)?;
    println!("added {name}; client config written to {}", out.display());
    Ok(())
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let mut file = load(&args.devices)?;
    match &args.cmd {
        Cmd::Add { name, out } => {
            anyhow::ensure!(
                valid_name(name),
                "device names are letters, digits, - and _"
            );
            anyhow::ensure!(
                !file.devices.iter().any(|d| &d.name == name && !d.revoked),
                "{name} already exists; use rotate to give it a new key"
            );
            file.devices.retain(|d| &d.name != name);
            enroll(&args, &mut file, name, None, out)?;
        }
        Cmd::Rotate { name, out } => {
            anyhow::ensure!(
                file.devices.iter().any(|d| &d.name == name),
                "no device named {name}"
            );
            let shield = file
                .devices
                .iter()
                .rev()
                .find(|d| &d.name == name)
                .and_then(|d| d.shield);
            retire(&mut file, name);
            enroll(&args, &mut file, name, shield, out)?;
        }
        Cmd::Revoke { name } => {
            anyhow::ensure!(revoke(&mut file, name), "no device named {name}");
            save(&args.devices, &file)?;
            println!("revoked {name}");
        }
        Cmd::List { json } => {
            if *json {
                println!("{}", serde_json::to_string_pretty(&file)?);
            } else {
                for d in &file.devices {
                    let state = if d.revoked { "revoked" } else { "active" };
                    println!("{:<20} {:<8} {}", d.name, state, d.added);
                }
            }
        }
        Cmd::Pubkey => println!("{}", exit_pubkey(&args.signing_secret)?),
        Cmd::Shield { name, state } => {
            let on = matches!(state, OnOff::On);
            let mut found = false;
            for d in file.devices.iter_mut().filter(|d| &d.name == name) {
                d.shield = (!on).then_some(false);
                found = true;
            }
            anyhow::ensure!(found, "no device named {name}");
            save(&args.devices, &file)?;
            println!("Shield {} for {name}", if on { "on" } else { "off" });
        }
        Cmd::Allow { domain } | Cmd::Unallow { domain } => {
            let domain = valid_domain(domain)?;
            let path = allow_path(&args.devices);
            let mut list = read_allow(&path);
            list.retain(|d| d != &domain);
            if matches!(&args.cmd, Cmd::Allow { .. }) {
                list.push(domain.clone());
            }
            list.sort();
            let tmp = path.with_extension("tmp");
            fs::write(
                &tmp,
                list.iter().map(|d| format!("{d}\n")).collect::<String>(),
            )?;
            fs::set_permissions(&tmp, fs::Permissions::from_mode(0o640))?;
            fs::rename(&tmp, &path)?;
            println!(
                "{} {domain}",
                if matches!(&args.cmd, Cmd::Allow { .. }) {
                    "allowed"
                } else {
                    "no longer allowed:"
                }
            );
        }
        Cmd::Allowed => {
            for d in read_allow(&allow_path(&args.devices)) {
                println!("{d}");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, pubkey: &str, revoked: bool) -> DeviceEntry {
        DeviceEntry {
            name: name.into(),
            pubkey: pubkey.into(),
            added: String::new(),
            revoked,
            shield: None,
            replaced: None,
        }
    }

    #[test]
    fn rotating_keeps_only_the_last_replaced_key() {
        let mut file = DeviceFile {
            devices: vec![entry("phone", "k1", false), entry("mac", "m1", false)],
        };
        retire(&mut file, "phone");
        file.devices.push(entry("phone", "k2", false));
        retire(&mut file, "phone");
        file.devices.push(entry("phone", "k3", false));
        let phone: Vec<(&str, bool)> = file
            .devices
            .iter()
            .filter(|d| d.name == "phone")
            .map(|d| (d.pubkey.as_str(), d.revoked))
            .collect();
        assert_eq!(phone, [("k2", true), ("k3", false)]);
        assert!(file.devices.iter().any(|d| d.name == "mac" && !d.revoked));
    }

    #[test]
    fn revoking_reaches_every_key_of_the_device() {
        let mut file = DeviceFile {
            devices: vec![entry("phone", "k2", true), entry("phone", "k3", false)],
        };
        assert!(revoke(&mut file, "phone"));
        assert!(file.devices.iter().all(|d| d.revoked));
        assert!(!revoke(&mut file, "tablet"));
    }

    #[test]
    fn only_domain_names_can_be_allowed() {
        assert_eq!(valid_domain(" Example.COM. ").unwrap(), "example.com");
        assert!(valid_domain("ads.example.co.uk").is_ok());
        for bad in [
            "",
            "localhost",
            "a..b",
            "x.com/evil",
            "x.com\nevil.com",
            "-",
        ] {
            assert!(valid_domain(bad).is_err(), "{bad:?} was accepted");
        }
    }

    #[test]
    fn device_files_from_before_shield_still_load() {
        let file: DeviceFile = serde_json::from_str(
            r#"{"devices":[{"name":"iphone","pubkey":"ab","added":"x","revoked":false}]}"#,
        )
        .unwrap();
        assert_eq!(file.devices[0].shield, None);
        let out = serde_json::to_string(&file).unwrap();
        assert!(!out.contains("shield") && !out.contains("replaced"));
    }
}
