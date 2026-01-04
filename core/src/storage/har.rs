use anyhow::{anyhow, Context};
use base64::{engine::general_purpose, Engine as _};
use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;

use crate::models::{HttpMethod, HttpTransaction, TransactionState, TransactionTiming};

const HAR_VERSION: &str = "1.2";
const CREATOR_NAME: &str = "Cheddar Proxy";
const CREATOR_VERSION: &str = env!("CARGO_PKG_VERSION");

struct ParsedUrlParts {
    scheme: String,
    host: String,
    port: u16,
    path_and_query: String,
}

fn parse_url_parts(url: &str) -> ParsedUrlParts {
    let (scheme, remainder) = if let Some(pos) = url.find("://") {
        (&url[..pos], &url[pos + 3..])
    } else {
        ("http", url)
    };

    let (authority, path_and_query) = if let Some(pos) = remainder.find('/') {
        (&remainder[..pos], &remainder[pos..])
    } else {
        (remainder, "/")
    };

    let (host, port) = split_host_port(authority, scheme);
    ParsedUrlParts {
        scheme: scheme.to_string(),
        host,
        port,
        path_and_query: if path_and_query.is_empty() {
            "/".to_string()
        } else {
            path_and_query.to_string()
        },
    }
}

fn split_host_port(authority: &str, scheme: &str) -> (String, u16) {
    if authority.is_empty() {
        return (String::new(), default_port(scheme));
    }

    if authority.starts_with('[') {
        if let Some(end) = authority.find(']') {
            let host = authority[..=end].to_string();
            let remainder = &authority[end + 1..];
            if let Some(stripped) = remainder.strip_prefix(':') {
                if let Ok(port) = stripped.parse::<u16>() {
                    return (host, port);
                }
            }
            return (host, default_port(scheme));
        }
    }

    if let Some(pos) = authority.rfind(':') {
        if authority[pos + 1..].chars().all(|c| c.is_ascii_digit()) {
            if let Ok(port) = authority[pos + 1..].parse::<u16>() {
                return (authority[..pos].to_string(), port);
            }
        }
    }

    (authority.to_string(), default_port(scheme))
}

fn default_port(scheme: &str) -> u16 {
    if scheme.eq_ignore_ascii_case("https") {
        443
    } else {
        80
    }
}

#[derive(Serialize)]
struct HarLog<'a> {
    log: HarLogInner<'a>,
}

#[derive(Serialize)]
struct HarLogInner<'a> {
    version: &'static str,
    creator: HarCreator<'a>,
    entries: Vec<HarEntry>,
}

#[derive(Serialize)]
struct HarCreator<'a> {
    name: &'a str,
    version: &'a str,
}

#[derive(Serialize)]
struct HarEntry {
    #[serde(rename = "startedDateTime")]
    started_datetime: String,
    time: i64,
    request: HarRequest,
    response: HarResponse,
    cache: HashMap<String, Value>,
    timings: HarTimings,
}

#[derive(Serialize)]
struct HarRequest {
    method: String,
    url: String,
    #[serde(rename = "httpVersion")]
    http_version: String,
    headers: Vec<HarHeader>,
    #[serde(rename = "queryString")]
    query_string: Vec<HarHeader>,
    cookies: Vec<Value>,
    #[serde(rename = "headersSize")]
    headers_size: i64,
    #[serde(rename = "bodySize")]
    body_size: i64,
    #[serde(skip_serializing_if = "Option::is_none", rename = "postData")]
    post_data: Option<HarPostData>,
}

#[derive(Serialize)]
struct HarResponse {
    status: i64,
    #[serde(rename = "statusText")]
    status_text: String,
    #[serde(rename = "httpVersion")]
    http_version: String,
    headers: Vec<HarHeader>,
    cookies: Vec<Value>,
    content: HarContent,
    #[serde(rename = "redirectURL")]
    redirect_url: String,
    #[serde(rename = "headersSize")]
    headers_size: i64,
    #[serde(rename = "bodySize")]
    body_size: i64,
}

#[derive(Clone, Serialize, Deserialize)]
struct HarHeader {
    name: String,
    value: String,
}

#[derive(Serialize)]
struct HarPostData {
    #[serde(rename = "mimeType")]
    mime_type: String,
    text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    encoding: Option<&'static str>,
}

#[derive(Serialize)]
struct HarContent {
    size: i64,
    #[serde(rename = "mimeType")]
    mime_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    encoding: Option<&'static str>,
}

#[derive(Serialize)]
struct HarTimings {
    send: i64,
    wait: i64,
    receive: i64,
}

pub fn transactions_to_har(transactions: &[HttpTransaction]) -> Value {
    let entries = transactions.iter().map(HarEntry::from).collect();
    serde_json::to_value(HarLog {
        log: HarLogInner {
            version: HAR_VERSION,
            creator: HarCreator {
                name: CREATOR_NAME,
                version: CREATOR_VERSION,
            },
            entries,
        },
    })
    .expect("serializing HAR log")
}

impl HarEntry {
    fn from(tx: &HttpTransaction) -> Self {
        let url = tx.full_url();
        let started_datetime = Utc
            .timestamp_millis_opt(tx.timing.start_time)
            .single()
            .unwrap_or_else(Utc::now)
            .to_rfc3339();
        let time = tx.timing.total_ms.unwrap_or(0) as i64;
        Self {
            started_datetime,
            time,
            request: HarRequest::from(tx, &url),
            response: HarResponse::from(tx),
            cache: HashMap::new(),
            timings: HarTimings {
                send: 0,
                wait: time,
                receive: 0,
            },
        }
    }
}

impl HarRequest {
    fn from(tx: &HttpTransaction, url: &str) -> Self {
        let headers = tx
            .request_headers
            .iter()
            .map(|(k, v)| HarHeader {
                name: k.clone(),
                value: v.clone(),
            })
            .collect();
        let query_string = parse_query_pairs(url);
        let (body_size, post_data) =
            encode_body(&tx.request_body, tx.request_content_type.as_deref());
        Self {
            method: tx.method.to_string(),
            url: url.to_string(),
            http_version: tx.http_version.clone(),
            headers,
            query_string,
            cookies: Vec::new(),
            headers_size: -1,
            body_size,
            post_data,
        }
    }
}

impl HarResponse {
    fn from(tx: &HttpTransaction) -> Self {
        let headers = tx
            .response_headers
            .clone()
            .unwrap_or_default()
            .into_iter()
            .map(|(k, v)| HarHeader { name: k, value: v })
            .collect::<Vec<_>>();
        let (body_size, content) = HarContent::from_body(
            &tx.response_body,
            tx.response_content_type.as_deref(),
            tx.response_size,
        );
        Self {
            status: tx.status_code.map(|c| c as i64).unwrap_or(0),
            status_text: tx.status_message.clone().unwrap_or_default(),
            http_version: tx.http_version.clone(),
            headers,
            cookies: Vec::new(),
            content,
            redirect_url: String::new(),
            headers_size: -1,
            body_size,
        }
    }
}

impl HarContent {
    fn from_body(
        body: &Option<Vec<u8>>,
        mime_type: Option<&str>,
        declared_size: Option<u64>,
    ) -> (i64, Self) {
        if let Some(bytes) = body {
            let (text, encoding) = match String::from_utf8(bytes.clone()) {
                Ok(text) => (Some(text), None),
                Err(_) => (
                    Some(general_purpose::STANDARD.encode(bytes)),
                    Some("base64"),
                ),
            };
            let size = declared_size
                .map(|s| s as i64)
                .unwrap_or(bytes.len() as i64);
            (
                size,
                Self {
                    size,
                    mime_type: mime_type.unwrap_or("application/octet-stream").to_string(),
                    text,
                    encoding,
                },
            )
        } else {
            let size = declared_size.map(|s| s as i64).unwrap_or(0);
            (
                size,
                Self {
                    size,
                    mime_type: mime_type.unwrap_or("application/octet-stream").to_string(),
                    text: None,
                    encoding: None,
                },
            )
        }
    }
}

fn encode_body(body: &Option<Vec<u8>>, mime_type: Option<&str>) -> (i64, Option<HarPostData>) {
    if let Some(bytes) = body {
        let (text, encoding) = match String::from_utf8(bytes.clone()) {
            Ok(text) => (text, None),
            Err(_) => (general_purpose::STANDARD.encode(bytes), Some("base64")),
        };
        (
            bytes.len() as i64,
            Some(HarPostData {
                mime_type: mime_type.unwrap_or("application/octet-stream").to_string(),
                text,
                encoding,
            }),
        )
    } else {
        (0, None)
    }
}

fn parse_query_pairs(url: &str) -> Vec<HarHeader> {
    let parts = parse_url_parts(url);
    if let Some(pos) = parts.path_and_query.find('?') {
        let query = &parts.path_and_query[pos + 1..];
        return split_query(query);
    }
    Vec::new()
}

fn split_query(query: &str) -> Vec<HarHeader> {
    query
        .split('&')
        .filter(|segment| !segment.is_empty())
        .map(|segment| {
            let mut parts = segment.splitn(2, '=');
            let name = percent_decode(parts.next().unwrap_or_default());
            let value = percent_decode(parts.next().unwrap_or_default());
            HarHeader { name, value }
        })
        .collect()
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut output = String::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                if let (Some(h), Some(l)) = (hex_value(bytes[i + 1]), hex_value(bytes[i + 2])) {
                    output.push((h << 4 | l) as char);
                    i += 3;
                    continue;
                }
                output.push('%');
                i += 1;
            }
            b'+' => {
                output.push(' ');
                i += 1;
            }
            ch => {
                output.push(ch as char);
                i += 1;
            }
        }
    }
    output
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[derive(Deserialize)]
struct RawHar {
    log: RawHarLog,
}

#[derive(Deserialize)]
struct RawHarLog {
    entries: Vec<RawHarEntry>,
}

#[derive(Deserialize)]
struct RawHarEntry {
    #[serde(rename = "startedDateTime")]
    started_datetime: Option<String>,
    time: Option<f64>,
    request: RawHarRequest,
    response: Option<RawHarResponse>,
}

#[derive(Deserialize)]
struct RawHarRequest {
    method: Option<String>,
    url: Option<String>,
    #[serde(rename = "httpVersion")]
    http_version: Option<String>,
    headers: Option<Vec<HarHeader>>,
    #[serde(rename = "postData")]
    post_data: Option<RawHarPostData>,
}

#[derive(Deserialize)]
struct RawHarPostData {
    #[serde(rename = "mimeType")]
    mime_type: Option<String>,
    text: Option<String>,
    encoding: Option<String>,
}

#[derive(Deserialize)]
struct RawHarResponse {
    status: Option<i64>,
    #[serde(rename = "statusText")]
    status_text: Option<String>,
    #[serde(rename = "httpVersion")]
    _http_version: Option<String>,
    headers: Option<Vec<HarHeader>>,
    content: Option<RawHarContent>,
}

#[derive(Deserialize)]
struct RawHarContent {
    #[serde(rename = "mimeType")]
    mime_type: Option<String>,
    text: Option<String>,
    encoding: Option<String>,
    size: Option<i64>,
}

pub fn har_to_transactions(value: &Value) -> anyhow::Result<Vec<HttpTransaction>> {
    let raw: RawHar = serde_json::from_value(value.clone())
        .map_err(|err| anyhow!("Invalid HAR structure: {err}"))?;
    raw.log
        .entries
        .into_iter()
        .map(entry_to_transaction)
        .collect()
}

fn entry_to_transaction(entry: RawHarEntry) -> anyhow::Result<HttpTransaction> {
    let url = entry
        .request
        .url
        .ok_or_else(|| anyhow!("HAR entry missing request url"))?;
    let method = entry
        .request
        .method
        .as_deref()
        .map(HttpMethod::from_str_lossy)
        .unwrap_or(HttpMethod::Get);
    let parts = parse_url_parts(&url);
    let scheme = parts.scheme;
    let host = parts.host;
    let port = parts.port;
    let path = parts.path_and_query;

    let request_headers = headers_to_map(entry.request.headers.unwrap_or_default());
    let (request_body, request_content_type) = decode_body(entry.request.post_data);

    let response = entry.response;
    let (status_code, status_text, response_headers, response_body, response_mime, response_size) =
        match response {
            Some(resp) => {
                let headers = resp.headers.map(headers_to_map).unwrap_or_default();
                let (body, mime, size) = decode_content(resp.content);
                (
                    resp.status.map(|s| s as u16),
                    resp.status_text,
                    Some(headers),
                    body,
                    mime,
                    size,
                )
            }
            None => (None, None, None, None, None, None),
        };

    let start_time = parse_start_time(entry.started_datetime);
    let timing = TransactionTiming {
        start_time,
        total_ms: entry.time.map(|t| t.max(0.0) as u32),
        ..Default::default()
    };

    Ok(HttpTransaction {
        id: uuid::Uuid::new_v4().to_string(),
        method,
        scheme,
        host,
        port: port as u16,
        path,
        http_version: entry
            .request
            .http_version
            .unwrap_or_else(|| "HTTP/1.1".to_string()),
        state: TransactionState::Completed,
        request_headers,
        request_body,
        request_content_type,
        status_code,
        status_message: status_text,
        response_headers,
        response_body,
        response_content_type: response_mime,
        timing,
        response_size,
        has_breakpoint: false,
        notes: None,
        server_ip: None,
        tls_version: None,
        tls_cipher: None,
        connection_reused: false,
        stream_id: None,
        is_websocket: false,
    })
}

fn headers_to_map(headers: Vec<HarHeader>) -> HashMap<String, String> {
    headers
        .into_iter()
        .map(|h| (h.name, h.value))
        .collect::<HashMap<_, _>>()
}

fn decode_body(post_data: Option<RawHarPostData>) -> (Option<Vec<u8>>, Option<String>) {
    if let Some(data) = post_data {
        if let Some(text) = data.text {
            let bytes = if matches!(data.encoding.as_deref(), Some("base64")) {
                general_purpose::STANDARD
                    .decode(text)
                    .unwrap_or_else(|_| Vec::new())
            } else {
                text.into_bytes()
            };
            (
                Some(bytes),
                data.mime_type
                    .or_else(|| Some("application/octet-stream".to_string())),
            )
        } else {
            (None, data.mime_type)
        }
    } else {
        (None, None)
    }
}

fn decode_content(
    content: Option<RawHarContent>,
) -> (Option<Vec<u8>>, Option<String>, Option<u64>) {
    if let Some(content) = content {
        let size = content.size.map(|s| s.max(0) as u64);
        if let Some(text) = content.text {
            let bytes = if matches!(content.encoding.as_deref(), Some("base64")) {
                general_purpose::STANDARD
                    .decode(text)
                    .unwrap_or_else(|_| Vec::new())
            } else {
                text.into_bytes()
            };
            (Some(bytes), content.mime_type, size)
        } else {
            (None, content.mime_type, size)
        }
    } else {
        (None, None, None)
    }
}

fn parse_start_time(value: Option<String>) -> i64 {
    if let Some(ts) = value {
        if let Ok(dt) = DateTime::parse_from_rfc3339(&ts) {
            return dt.timestamp_millis();
        }
    }
    Utc::now().timestamp_millis()
}

pub async fn export_har_to_path(
    transactions: Vec<HttpTransaction>,
    output_path: impl AsRef<Path>,
) -> anyhow::Result<usize> {
    if transactions.is_empty() {
        return Err(anyhow!("No transactions to export"));
    }
    let value = transactions_to_har(&transactions);
    let json = serde_json::to_string_pretty(&value)?;
    std::fs::write(output_path, json).context("writing HAR file")?;
    Ok(transactions.len())
}

pub fn import_har_from_str(contents: &str) -> anyhow::Result<Vec<HttpTransaction>> {
    let value: Value =
        serde_json::from_str(contents).map_err(|err| anyhow!("Failed to parse HAR JSON: {err}"))?;
    let transactions = har_to_transactions(&value)?;
    if transactions.is_empty() {
        Err(anyhow!("HAR file contains no entries"))
    } else {
        Ok(transactions)
    }
}

pub fn import_har_from_path(path: impl AsRef<Path>) -> anyhow::Result<Vec<HttpTransaction>> {
    let data = std::fs::read_to_string(path).context("reading HAR file")?;
    import_har_from_str(&data)
}
