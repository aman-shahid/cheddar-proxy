use super::{CertTrustStatus, PlatformProxyAdapter};
use anyhow::{anyhow, Result};
use std::process::Command;

pub struct WindowsProxyAdapter;

impl WindowsProxyAdapter {
    pub const fn new() -> Self {
        Self
    }

    fn run_netsh(args: &[&str]) -> Result<()> {
        let status = Command::new("netsh").args(args).status();
        match status {
            Ok(code) if code.success() => Ok(()),
            Ok(code) => Err(anyhow!("netsh exited with {}", code)),
            Err(err) => Err(anyhow!(err)),
        }
    }

    fn run_certutil(args: &[&str]) -> Result<bool> {
        let status = Command::new("certutil").args(args).status();
        match status {
            Ok(code) if code.success() => Ok(true),
            Ok(_) => Ok(false),
            Err(err) => Err(anyhow!(err)),
        }
    }
}

impl PlatformProxyAdapter for WindowsProxyAdapter {
    fn enable_system_proxy(&self, host: &str, port: u16) -> Result<()> {
        let proxy = format!("{}:{}", host, port);
        Self::run_netsh(&["winhttp", "set", "proxy", &proxy])
    }

    fn disable_system_proxy(&self) -> Result<()> {
        // `netsh winhttp reset proxy` returns exit code 1 in multiple scenarios:
        // - No proxy was set (shows "Direct access")
        // - Access denied but already in direct mode
        // - Nothing to reset
        // All of these are acceptable outcomes for "disable proxy".
        let output = Command::new("netsh")
            .args(["winhttp", "reset", "proxy"])
            .output();
        match output {
            Ok(out) if out.status.success() => Ok(()),
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                let stdout = String::from_utf8_lossy(&out.stdout);
                let combined = format!("{}{}", stdout, stderr);
                let combined_lower = combined.to_lowercase();

                // Accept as success if:
                // 1. "direct access" is mentioned (no proxy set / already direct)
                // 2. "no proxy" is mentioned
                // 3. The system is already in the desired state (proxy disabled)
                if combined_lower.contains("direct access") || combined_lower.contains("no proxy") {
                    Ok(())
                } else {
                    Err(anyhow!(
                        "netsh exited with exit code: {}",
                        out.status.code().unwrap_or(-1)
                    ))
                }
            }
            Err(err) => Err(anyhow!(err)),
        }
    }
    fn detect_certificate_trust(&self, common_name: &str) -> Result<CertTrustStatus> {
        let query = format!("Root {}", common_name);
        let trusted =
            match Self::run_certutil(&["-store", "-user", "Root", &query]).unwrap_or_default() {
                Ok(found) => found,
                Err(_) => false,
            };
        Ok(if trusted {
            CertTrustStatus::Trusted
        } else {
            CertTrustStatus::NotTrusted
        })
    }
}
