//! WebSocket frame parsing
//!
//! Parses WebSocket frames according to RFC 6455

use crate::models::{MessageDirection, WebSocketMessage, WebSocketOpcode};

/// Maximum payload we'll capture per frame (to avoid memory issues with large binary frames)
const MAX_CAPTURE_SIZE: usize = 256 * 1024; // 256KB

/// Parsed WebSocket frame header
#[derive(Debug, Clone)]
pub struct FrameHeader {
    pub fin: bool,
    pub opcode: WebSocketOpcode,
    pub masked: bool,
    pub payload_len: u64,
    pub mask_key: Option<[u8; 4]>,
    pub header_len: usize,
}

/// Parse a WebSocket frame header from the buffer
/// Returns None if not enough data is available
pub fn parse_frame_header(data: &[u8]) -> Option<FrameHeader> {
    if data.len() < 2 {
        return None;
    }

    let fin = (data[0] & 0x80) != 0;
    let opcode = WebSocketOpcode::from_u8(data[0] & 0x0F)?;
    let masked = (data[1] & 0x80) != 0;
    let mut payload_len = (data[1] & 0x7F) as u64;

    let mut offset = 2;

    // Extended payload length
    if payload_len == 126 {
        if data.len() < offset + 2 {
            return None;
        }
        payload_len = u16::from_be_bytes([data[offset], data[offset + 1]]) as u64;
        offset += 2;
    } else if payload_len == 127 {
        if data.len() < offset + 8 {
            return None;
        }
        payload_len = u64::from_be_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
            data[offset + 4],
            data[offset + 5],
            data[offset + 6],
            data[offset + 7],
        ]);
        offset += 8;
    }

    // Masking key (only present for client -> server frames)
    let mask_key = if masked {
        if data.len() < offset + 4 {
            return None;
        }
        let key = [
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ];
        offset += 4;
        Some(key)
    } else {
        None
    };

    Some(FrameHeader {
        fin,
        opcode,
        masked,
        payload_len,
        mask_key,
        header_len: offset,
    })
}

/// Unmask payload data in place
pub fn unmask_payload(data: &mut [u8], mask_key: [u8; 4]) {
    for (i, byte) in data.iter_mut().enumerate() {
        *byte ^= mask_key[i % 4];
    }
}

/// Try to extract a complete WebSocket frame and create a message
/// Returns (message, bytes_consumed) or None if not enough data
pub fn extract_message(
    data: &[u8],
    connection_id: &str,
    direction: MessageDirection,
) -> Option<(WebSocketMessage, usize)> {
    let header = parse_frame_header(data)?;

    let total_len = header.header_len + header.payload_len as usize;
    if data.len() < total_len {
        return None;
    }

    // Extract payload
    let payload_start = header.header_len;
    let payload_end = payload_start + header.payload_len as usize;
    let mut payload = data[payload_start..payload_end].to_vec();

    // Unmask if needed
    if let Some(mask_key) = header.mask_key {
        unmask_payload(&mut payload, mask_key);
    }

    // Truncate large payloads for storage
    let captured_payload = if payload.len() > MAX_CAPTURE_SIZE {
        payload[..MAX_CAPTURE_SIZE].to_vec()
    } else {
        payload
    };

    let msg = WebSocketMessage::new(
        connection_id.to_string(),
        direction,
        header.opcode,
        captured_payload,
        header.fin,
    );

    Some((msg, total_len))
}
