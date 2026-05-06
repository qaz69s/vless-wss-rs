use std::io;
use uuid::Uuid;
use subtle::ConstantTimeEq;

/// VLESS protocol parsing — server side.
///
/// Wire format of the first packet (after TLS + WebSocket handshake):
/// [1] version   — must be 0x01
/// [16] UUID
/// [1] auth_len
/// [N] auth_header (unused in basic mode)
/// [1] command   — 0x01=TCP 0x02=UDP
/// [1] addr_type — 0x01=IPv4 0x02=domain 0x03=IPv6
/// [N] addr
/// [2] port (BE)
/// ... body

pub const VLESS_VERSION: u8 = 0x00;
pub const CMD_TCP: u8 = 0x01;
pub const CMD_UDP: u8 = 0x02;
pub const ADDR_IPV4: u8 = 0x01;
pub const ADDR_DOMAIN: u8 = 0x02;
pub const ADDR_IPV6: u8 = 0x03;

// Minimum: version(1) + UUID(16) + auth_len(1) + command(1) + addr_type(1) + port(2) = 22
pub const MIN_FIRST_PKT: usize = 22;

/// Parse the VLESS first packet. Returns (command, target_addr, target_port, extra_bytes).
pub fn parse_first_packet(data: &[u8], expected_uuid: &Uuid) -> io::Result<(u8, String, u16, Vec<u8>)> {
    if data.len() < MIN_FIRST_PKT {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "packet too short"));
    }

    // version check
    if data[0] != VLESS_VERSION {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "bad VLESS version"));
    }

    // UUID check — constant-time comparison to resist timing attacks
    // FIX #5: was using `!=` (variable-time); now uses subtle::ConstantTimeEq
    let pkt_uuid = Uuid::from_bytes(data[1..17].try_into().unwrap());
    if expected_uuid.as_bytes().ct_eq(pkt_uuid.as_bytes()).unwrap_u8() == 0 {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "UUID mismatch"));
    }

    let auth_len = data[17] as usize;

    // FIX #2: validate command byte is within bounds before reading.
    // Original code accessed data[18 + auth_len] without checking length,
    // causing a panic whenever auth_len > 0 and the packet was too short.
    let command_idx = 18 + auth_len;
    if command_idx >= data.len() {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "auth header truncated"));
    }
    let command = data[command_idx];

    let addr_type_idx = 19 + auth_len;
    if addr_type_idx >= data.len() {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "addr_type missing"));
    }

    let (addr, addr_len) = match data[addr_type_idx] {
        ADDR_IPV4 => {
            if data.len() < addr_type_idx + 1 + 4 + 2 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "IPv4 truncated"));
            }
            let ip = format!("{}.{}.{}.{}",
                data[addr_type_idx+1], data[addr_type_idx+2],
                data[addr_type_idx+3], data[addr_type_idx+4]);
            (ip, 4)
        }
        ADDR_DOMAIN => {
            if data.len() < addr_type_idx + 2 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "domain len missing"));
            }
            let dom_len = data[addr_type_idx + 1] as usize;
            if data.len() < addr_type_idx + 1 + 1 + dom_len + 2 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "domain truncated"));
            }
            let domain = String::from_utf8_lossy(
                &data[addr_type_idx+2..addr_type_idx+2+dom_len]
            ).to_string();
            (domain, 1 + dom_len)
        }
        ADDR_IPV6 => {
            if data.len() < addr_type_idx + 1 + 16 + 2 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "IPv6 truncated"));
            }
            let segments: Vec<String> = (0..8)
                .map(|i| format!("{:x}", u16::from_be_bytes(
                    [data[addr_type_idx+1+i*2], data[addr_type_idx+2+i*2]]
                )))
                .collect();
            (segments.join(":"), 16)
        }
        t => return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unknown addr type 0x{:02x}", t),
        )),
    };

    let port_start = addr_type_idx + 1 + addr_len;
    let port = u16::from_be_bytes([data[port_start], data[port_start+1]]);
    let body = data[port_start+2..].to_vec();

    Ok((command, addr, port, body))
}
