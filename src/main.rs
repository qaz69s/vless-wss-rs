mod vless;
mod ws;

use clap::Parser;
use std::fs;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use rustls::ServerConfig;
use log::{info, error, warn};

const CONFIG_FILE: &str = "/etc/vless-wss-rs/config.json";

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Config {
    uuid: Option<String>,
    domain: Option<String>,
}

#[derive(Parser, Debug)]
#[command(about = "VLESS WSS Server")]
struct Args {
    /// TLS certificate (PEM)
    #[arg(long)]
    cert: Option<PathBuf>,

    /// TLS private key (PEM)
    #[arg(long)]
    key: Option<PathBuf>,

    /// Issue a Let's Encrypt certificate for this domain
    #[arg(long)]
    get_cert: Option<String>,

    /// Email for Let's Encrypt registration
    #[arg(long)]
    email: Option<String>,

    /// Listen address
    #[arg(long, default_value = "0.0.0.0:8443")]
    listen: String,

    /// VLESS user UUID (auto-generated if not provided)
    #[arg(long)]
    uuid: Option<String>,

    /// Cloudflare DNS API token (for DNS-01 challenge)
    #[arg(long)]
    cf_token: Option<String>,
}

fn load_config() -> Config {
    fs::read_to_string(CONFIG_FILE)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_config(uuid: &str, domain: &str) -> std::io::Result<()> {
    let cfg = Config {
        uuid: Some(uuid.to_string()),
        domain: Some(domain.to_string()),
    };
    fs::create_dir_all("/etc/vless-wss-rs")?;
    fs::write(CONFIG_FILE, serde_json::to_string_pretty(&cfg)?)?;
    Ok(())
}

fn generate_uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}

fn print_vless_link(uuid: &str, domain: &str, port: u16) {
    // VLESS URI for V2Ray/NekoRay/clash-meta
    // type=ws, tls with SNI
    println!();
    println!("============================================");
    println!("  VLESS WSS 节点链接:");
    println!("============================================");
    println!("vless://{}@{}:{}?encryption=none&flow=xtls-rprx-vision&security=tls&sni={}&fp=chrome&type=ws&host={}&path=%2F#{}",
        uuid, domain, port, domain, domain, domain);
    println!("============================================");
    println!();
    println!("Config saved to: {}", CONFIG_FILE);
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();

    let args = Args::parse();
    let mut config = load_config();

    // Determine domain
    let domain = match &args.get_cert {
        Some(d) => d.clone(),
        None => config.domain.clone()
            .ok_or("need --get-cert or previous domain in config")?,
    };

    // Determine UUID
    let uuid = match &args.uuid {
        Some(u) => u.clone(),
        None => config.uuid.clone()
            .unwrap_or_else(generate_uuid),
    };

    // Save config
    save_config(&uuid, &domain)?;

    // Determine where certs live
    let (cert_path, key_path) = match (&args.cert, &args.key) {
        (Some(c), Some(k)) => (c.clone(), k.clone()),
        _ => {
            let email = args.email.as_ref().ok_or("need --email for Let's Encrypt")?;
            let cf_token = args.cf_token.as_ref().ok_or("need --cf-token for DNS-01 challenge")?;

            issue_cert(&domain, email, cf_token).await?;
            let cert = PathBuf::from(format!("/root/.acme.sh/{}/fullchain.cer", domain));
            let key = PathBuf::from(format!("/root/.acme.sh/{}/{}", domain, domain));
            (cert, key)
        }
    };

    let cert_pem = tokio::fs::read(&cert_path).await?;
    let key_pem = tokio::fs::read(&key_path).await?;

    let certs: Vec<_> = rustls_pemfile::certs(&mut cert_pem.as_slice())
        .collect::<Result<_, _>>()?;

    let key = if let Some(k) = rustls_pemfile::pkcs8_private_keys(&mut key_pem.as_slice())
        .filter_map(|k| k.ok()).next()
    {
        rustls::pki_types::PrivateKeyDer::Pkcs8(k)
    } else {
        let k = rustls_pemfile::rsa_private_keys(&mut key_pem.as_slice())
            .filter_map(|k| k.ok()).next()
            .ok_or("no private key found")?;
        rustls::pki_types::PrivateKeyDer::Pkcs1(k)
    };

    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)?;

    let acceptor = TlsAcceptor::from(Arc::new(config));

    let addr: SocketAddr = args.listen.parse()?;
    let listener = TcpListener::bind(addr).await?;

    // Extract port from addr
    let port = addr.port();

    println!();
    info!("Listening on {}", addr);
    println!();

    // Print the VLESS link
    print_vless_link(&uuid, &domain, port);

    loop {
        let (stream, peer) = listener.accept().await?;
        let acc = TlsAcceptor::clone(&acceptor);
        let uuid = args.uuid.clone().unwrap_or_else(|| uuid.clone());

        tokio::spawn(async move {
            match acc.accept(stream).await {
                Ok(tls) => {
                    if let Err(e) = ws::handle_connection(tls, &uuid, peer).await {
                        error!("[{}] connection error: {}", peer, e);
                    }
                }
                Err(e) => {
                    error!("TLS handshake failed from {}: {}", peer, e);
                }
            }
        });
    }
}

/// Use acme.sh via DNS-01 (Cloudflare) to issue a Let's Encrypt certificate.
async fn issue_cert(
    domain: &str,
    email: &str,
    cf_token: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    info!("Issuing Let's Encrypt certificate for {}", domain);

    // Ensure acme.sh is installed
    let which = Command::new("sh")
        .args(["-c", "which acme.sh"])
        .output()?;

    if !which.status.success() {
        warn!("acme.sh not found, installing...");
        let out = Command::new("sh")
            .args(["-c", &format!("curl https://get.acme.sh | sh -s email={}", email)])
            .output()?;
        if !out.status.success() {
            return Err(format!("acme.sh install failed: {}",
                String::from_utf8_lossy(&out.stderr)).into());
        }
    }

    // Set Cloudflare DNS token
    let set_cf = Command::new("sh")
        .args(["-c", &format!(
            "export CF_Token=\"{}\" && ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt",
            cf_token
        )])
        .output()?;
    if !set_cf.status.success() {
        warn!("set-default-ca: {}",
            String::from_utf8_lossy(&set_cf.stderr));
    }

    // Issue certificate via DNS-01
    let out = Command::new("sh")
        .args(["-c", &format!(
            "export CF_Token=\"{}\" && ~/.acme.sh/acme.sh --issue --dns dns_cf -d {} --keylength 2048 --server letsencrypt",
            cf_token, domain
        )])
        .output()?;

    if !out.status.success() {
        return Err(format!("acme.sh issue failed: {}",
            String::from_utf8_lossy(&out.stderr)).into());
    }

    info!("Certificate issued: /root/.acme.sh/{}/fullchain.cer", domain);
    Ok(())
}
