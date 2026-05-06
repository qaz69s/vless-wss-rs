mod vless;
mod ws;

use clap::Parser;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use rustls::ServerConfig;
use rustls::crypto::CryptoProvider;
use log::{info, error};

#[derive(Parser, Debug)]
#[command(about = "VLESS WSS Server")]
struct Args {
    /// TLS certificate (PEM)
    #[arg(long)]
    cert: PathBuf,

    /// TLS private key (PEM)
    #[arg(long)]
    key: PathBuf,

    /// Listen address
    #[arg(long, default_value = "0.0.0.0:443")]
    listen: String,

    /// VLESS user UUID
    #[arg(long)]
    uuid: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();

    // rustls 0.23+ 要求显式安装 CryptoProvider
    CryptoProvider::install_default(
        rustls::crypto::ring::default_provider()
    ).ok();

    let args = Args::parse();

    let cert_pem = tokio::fs::read(&args.cert).await?;
    let key_pem  = tokio::fs::read(&args.key).await?;

    let certs: Vec<_> = rustls_pemfile::certs(&mut cert_pem.as_slice())
        .collect::<Result<_, _>>()?;

    let key = if let Some(k) = rustls_pemfile::pkcs8_private_keys(&mut key_pem.as_slice())
        .filter_map(|k| k.ok()).next()
    {
        rustls::pki_types::PrivateKeyDer::Pkcs8(k)
    } else {
        let k = rustls_pemfile::rsa_private_keys(&mut key_pem.as_slice())
            .filter_map(|k| k.ok()).next()
            .ok_or("no private key found in PEM")?;
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
        let acc  = TlsAcceptor::clone(&acceptor);
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
