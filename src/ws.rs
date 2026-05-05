use log::{info, error, debug};
use std::net::SocketAddr;
use std::io::{self, ErrorKind};
use tokio::net::TcpStream;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::{accept_async, WebSocketStream};
use tokio_rustls::server::TlsStream;
use futures_util::{StreamExt, SinkExt};
use uuid::Uuid;
use crate::vless;

pub async fn handle_connection(
    tls_stream: TlsStream<TcpStream>,
    expected_uuid: &str,
    peer: SocketAddr,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let expected = Uuid::parse_str(expected_uuid)
        .map_err(|e| io::Error::new(ErrorKind::InvalidInput, format!("bad UUID: {}", e)))?;

    let mut ws = accept_async(tls_stream).await?;
    info!("WS accepted from {}", peer);

    // Read first binary frame = VLESS first packet
    let msg = ws.next().await
        .ok_or_else(|| io::Error::new(ErrorKind::UnexpectedEof, "no first message"))??;

    let first_data = msg.into_data();
    debug!("first packet {} bytes", first_data.len());

    let (cmd, addr, port, body) = vless::parse_first_packet(&first_data, &expected)
        .map_err(|e| { error!("VLESS parse error from {}: {}", peer, e); e })?;

    info!("[{}] cmd={} -> {}:{}", peer, cmd, addr, port);

    if cmd != vless::CMD_TCP {
        return Err(io::Error::new(ErrorKind::Unsupported, "only TCP supported").into());
    }

    let target = format!("{}:{}", addr, port);
    let mut upstream = TcpStream::connect(&target).await
        .map_err(|e| { error!("upstream connect failed: {}", e); e })?;

    if !body.is_empty() {
        upstream.write_all(&body).await?;
    }

    // Pass ownership of ws into relay
    relay_ws_upstream(ws, upstream, peer).await?;

    info!("[{}] connection closed", peer);
    Ok(())
}

/// Relay WebSocket <-> upstream TCP.
async fn relay_ws_upstream(
    ws: WebSocketStream<TlsStream<TcpStream>>,
    mut upstream: TcpStream,
    peer: SocketAddr,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (mut ws_sink, mut ws_stream) = ws.split();
    let (mut up_rd, mut up_wr) = upstream.split();

    // ws -> upstream: receive WebSocket binary messages, forward raw bytes
    let ws_to_up = async {
        loop {
            match ws_stream.next().await {
                Some(Ok(msg)) => {
                    let data = msg.into_data();
                    if data.is_empty() {
                        continue;
                    }
                    if up_wr.write_all(&data).await.is_err() {
                        break;
                    }
                }
                Some(Err(_)) | None => break,
            }
        }
        let _ = up_wr.shutdown().await;
        debug!("[{}] ws->upstream done", peer);
    };

    // upstream -> ws: read TCP bytes, send as WebSocket binary frames
    let up_to_ws = async {
        let mut buf = vec![0u8; 65536];
        loop {
            match up_rd.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    let msg = tokio_tungstenite::tungstenite::Message::Binary(buf[..n].to_vec().into());
                    if ws_sink.send(msg).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = ws_sink.close().await;
        debug!("[{}] upstream->ws done", peer);
    };

    tokio::join!(ws_to_up, up_to_ws);
    Ok(())
}
