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
    Ok(hex::encode(SigningKey::from_bytes(&bytes).verifying_key().as_bytes()))
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

fn enroll(args: &Args, file: &mut DeviceFile, name: &str, out: &Path) -> anyhow::Result<()> {
    let device = KestrelDevice::generate(name);
    let config = client_config(args, &device)?;
    file.devices.push(DeviceEntry {
        name: name.to_string(),
        pubkey: device.public_key_hex()?,
        added: today(),
        revoked: false,
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
            anyhow::ensure!(valid_name(name), "device names are letters, digits, - and _");
            anyhow::ensure!(
                !file.devices.iter().any(|d| &d.name == name && !d.revoked),
                "{name} already exists; use rotate to give it a new key"
            );
            file.devices.retain(|d| &d.name != name);
            enroll(&args, &mut file, name, out)?;
        }
        Cmd::Rotate { name, out } => {
            anyhow::ensure!(
                file.devices.iter().any(|d| &d.name == name),
                "no device named {name}"
            );
            file.devices.retain(|d| &d.name != name);
            enroll(&args, &mut file, name, out)?;
        }
        Cmd::Revoke { name } => {
            let dev = file
                .devices
                .iter_mut()
                .find(|d| &d.name == name)
                .with_context(|| format!("no device named {name}"))?;
            dev.revoked = true;
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
    }
    Ok(())
}
