mod vless;
mod ws;

use clap::Parser;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use rustls::ServerConfig;
use log::{info, error, warn};

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

    /// VLESS user UUID
    #[arg(long)]
    uuid: String,

    /// Cloudflare DNS API token (for DNS-01 challenge)
    #[arg(long)]
    cf_token: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();

    let args = Args::parse();

    // Determine where certs live
    let (cert_path, key_path) = match (&args.cert, &args.key) {
        (Some(c), Some(k)) => (c.clone(), k.clone()),
        _ => {
            let domain = args.get_cert.as_ref().ok_or("need --cert/--key or --get-cert")?;
            let email = args.email.as_ref().ok_or("need --email for Let's Encrypt")?;
            let cf_token = args.cf_token.as_ref().ok_or("need --cf-token for DNS-01 challenge")?;

            issue_cert(domain, email, cf_token).await?;
            let domain = domain;
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
    info!("Listening on {}", addr);

    loop {
        let (stream, peer) = listener.accept().await?;
        let acc = TlsAcceptor::clone(&acceptor);
        let uuid = args.uuid.clone();

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
        warn!("set-default-ca failed (may already be set): {}",
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
