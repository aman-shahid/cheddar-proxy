use std::path::PathBuf;

#[cfg(not(unix))]
use anyhow::anyhow;
use anyhow::{Context, Result};
use tokio::io::{self, AsyncWriteExt};
use tokio::net::TcpStream;
#[cfg(unix)]
use tokio::net::UnixStream;

#[derive(Debug, PartialEq, Eq)]
enum Target {
    #[cfg(unix)]
    Unix(PathBuf),
    Tcp(String),
}

#[derive(Debug, PartialEq, Eq)]
struct BridgeConfig {
    target: Target,
}

fn parse_args() -> Result<BridgeConfig> {
    parse_args_from(std::env::args().skip(1))
}

fn parse_args_from<I>(mut args: I) -> Result<BridgeConfig>
where
    I: Iterator<Item = String>,
{
    let mut socket_path: Option<PathBuf> = None;
    let mut tcp_addr: Option<String> = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socket" => {
                if let Some(path) = args.next() {
                    socket_path = Some(PathBuf::from(path));
                }
            }
            "--tcp" | "--addr" => {
                if let Some(addr) = args.next() {
                    tcp_addr = Some(addr);
                }
            }
            "--help" | "-h" => {
                eprintln!("Cheddar Proxy MCP Bridge");
                eprintln!();
                eprintln!("Usage: cheddarproxy_mcp_bridge [--socket <PATH>] [--tcp <HOST:PORT>]");
                eprintln!("  --socket <PATH>   Path to the Unix socket exposed by Cheddar Proxy");
                eprintln!("  --tcp <HOST:PORT> TCP loopback address of the MCP server (Windows/macOS/Linux)");
                std::process::exit(0);
            }
            _ => {
                eprintln!("Unknown argument: {arg}");
            }
        }
    }

    #[cfg(unix)]
    {
        if let Some(path) = socket_path {
            return Ok(BridgeConfig {
                target: Target::Unix(path),
            });
        }
    }

    if let Some(addr) = tcp_addr {
        return Ok(BridgeConfig {
            target: Target::Tcp(addr),
        });
    }

    #[cfg(unix)]
    // Default to the Unix socket path for existing macOS/Linux behavior.
    return Ok(BridgeConfig {
        target: Target::Unix(PathBuf::from("/tmp/cheddarproxy_mcp.sock")),
    });

    #[cfg(not(unix))]
    Err(anyhow!(
        "No MCP endpoint provided. Pass --tcp <HOST:PORT> (Windows) or --socket <PATH>."
    ))
}

#[cfg(unix)]
async fn run_unix_socket(path: &PathBuf) -> Result<()> {
    let stream = UnixStream::connect(path)
        .await
        .with_context(|| format!("Failed to connect to MCP socket at {}", path.display()))?;

    let (mut socket_reader, mut socket_writer) = stream.into_split();
    let mut stdin = io::stdin();
    let mut stdout = io::stdout();

    let client_to_server = tokio::spawn(async move {
        let result = io::copy(&mut stdin, &mut socket_writer).await;
        let _ = socket_writer.shutdown().await;
        result.context("Failed to forward MCP traffic from stdin to socket")
    });

    let server_to_client = tokio::spawn(async move {
        let result = io::copy(&mut socket_reader, &mut stdout).await;
        stdout
            .flush()
            .await
            .context("Failed to flush stdout after MCP copy")?;
        result.context("Failed to forward MCP traffic from socket to stdout")
    });

    let (a, b) = tokio::try_join!(client_to_server, server_to_client)?;
    a?;
    b?;
    Ok(())
}

async fn run_tcp(addr: &str) -> Result<()> {
    let stream = TcpStream::connect(addr)
        .await
        .with_context(|| format!("Failed to connect to MCP TCP endpoint at {addr}"))?;

    let (mut socket_reader, mut socket_writer) = stream.into_split();
    let mut stdin = io::stdin();
    let mut stdout = io::stdout();

    let client_to_server = tokio::spawn(async move {
        let result = io::copy(&mut stdin, &mut socket_writer).await;
        let _ = socket_writer.shutdown().await;
        result.context("Failed to forward MCP traffic from stdin to TCP socket")
    });

    let server_to_client = tokio::spawn(async move {
        let result = io::copy(&mut socket_reader, &mut stdout).await;
        stdout
            .flush()
            .await
            .context("Failed to flush stdout after MCP copy")?;
        result.context("Failed to forward MCP traffic from TCP socket to stdout")
    });

    let (a, b) = tokio::try_join!(client_to_server, server_to_client)?;
    a?;
    b?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let config = parse_args()?;

    match config.target {
        #[cfg(unix)]
        Target::Unix(path) => run_unix_socket(&path).await,
        Target::Tcp(addr) => run_tcp(&addr).await,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn default_unix_socket_is_used_when_no_args() {
        let cfg = parse_args_from(Vec::<String>::new().into_iter()).unwrap();
        match cfg.target {
            Target::Unix(path) => {
                assert_eq!(path, PathBuf::from("/tmp/cheddarproxy_mcp.sock"));
            }
            _ => panic!("expected unix target"),
        }
    }

    #[test]
    fn tcp_arg_parses_host_port() {
        let cfg =
            parse_args_from(vec!["--tcp".into(), "127.0.0.1:5555".into()].into_iter()).unwrap();

        match cfg.target {
            #[cfg(unix)]
            Target::Unix(_) => panic!("should be tcp"),
            Target::Tcp(addr) => assert_eq!(addr, "127.0.0.1:5555"),
        }
    }
}
