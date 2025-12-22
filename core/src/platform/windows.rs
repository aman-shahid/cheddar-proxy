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
        Self::run_netsh(&["winhttp", "reset", "proxy"])
    }

    fn detect_certificate_trust(&self, common_name: &str) -> Result<CertTrustStatus> {
        let query = format!("Root {}", common_name);
        let trusted = match Self::run_certutil(&["-store", "-user", "Root", &query]) {
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
