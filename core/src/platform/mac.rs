use super::{CertTrustStatus, PlatformProxyAdapter};
use anyhow::{anyhow, Context, Result};
use std::process::Command;
use tracing::warn;

pub struct MacProxyAdapter;

impl MacProxyAdapter {
    pub const fn new() -> Self {
        Self
    }

    fn run_networksetup(args: &[&str]) -> Result<()> {
        let output = Command::new("networksetup")
            .args(args)
            .output()
            .with_context(|| format!("failed to run networksetup with args {:?}", args))?;
        if output.status.success() {
            return Ok(());
        }

        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(anyhow!("networksetup {:?} failed: {}", args, stderr.trim()))
    }

    fn list_network_services() -> Result<Vec<String>> {
        let output = Command::new("networksetup")
            .arg("-listallnetworkservices")
            .output()
            .context("failed to list network services")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow!(
                "networksetup -listallnetworkservices failed: {}",
                stderr.trim()
            ));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let services = stdout
            .lines()
            .filter_map(|line| {
                let trimmed = line.trim();
                if trimmed.is_empty()
                    || trimmed.starts_with("An asterisk")
                    || trimmed.starts_with('*')
                {
                    return None;
                }
                Some(trimmed.to_string())
            })
            .collect::<Vec<_>>();

        Ok(services)
    }

    fn default_services() -> Vec<String> {
        vec!["Wi-Fi".to_string(), "Ethernet".to_string()]
    }

    fn resolve_services() -> Vec<String> {
        match Self::list_network_services() {
            Ok(services) if !services.is_empty() => services,
            Ok(_) => {
                warn!("No network services reported; falling back to defaults");
                Self::default_services()
            }
            Err(err) => {
                warn!(
                    ?err,
                    "Failed to enumerate network services; falling back to defaults"
                );
                Self::default_services()
            }
        }
    }

    fn normalize_host(host: &str) -> String {
        let trimmed = host.trim();
        let stripped = trimmed
            .strip_prefix("http://")
            .or_else(|| trimmed.strip_prefix("https://"))
            .unwrap_or(trimmed);
        stripped
            .split('/')
            .next()
            .unwrap_or(stripped)
            .trim()
            .to_string()
    }

    fn configure_proxy(&self, host: &str, port: u16, state: &str) -> Result<()> {
        let services = Self::resolve_services();
        if services.is_empty() {
            return Err(anyhow!(
                "No network services available for proxy configuration"
            ));
        }

        let host = Self::normalize_host(host);
        let port_str = port.to_string();

        for service in services {
            let service_ref = service.as_str();
            let host_ref = host.as_str();
            let port_ref = port_str.as_str();

            Self::run_networksetup(&["-setwebproxy", service_ref, host_ref, port_ref])?;
            Self::run_networksetup(&["-setsecurewebproxy", service_ref, host_ref, port_ref])?;
            Self::run_networksetup(&["-setwebproxystate", service_ref, state])?;
            Self::run_networksetup(&["-setsecurewebproxystate", service_ref, state])?;
        }
        Ok(())
    }

    fn run_security(args: &[&str]) -> Result<bool> {
        let status = Command::new("security").args(args).status();
        match status {
            Ok(code) if code.success() => Ok(true),
            Ok(_) => Ok(false),
            Err(err) => Err(anyhow!(err)),
        }
    }
}

impl PlatformProxyAdapter for MacProxyAdapter {
    fn enable_system_proxy(&self, host: &str, port: u16) -> Result<()> {
        self.configure_proxy(host, port, "on")
    }

    fn disable_system_proxy(&self) -> Result<()> {
        let services = Self::resolve_services();
        if services.is_empty() {
            return Err(anyhow!(
                "No network services available for proxy configuration"
            ));
        }

        for service in services {
            let service_ref = service.as_str();
            Self::run_networksetup(&["-setwebproxystate", service_ref, "off"])?;
            Self::run_networksetup(&["-setsecurewebproxystate", service_ref, "off"])?;
        }
        Ok(())
    }

    fn detect_certificate_trust(&self, common_name: &str) -> Result<CertTrustStatus> {
        let trusted = Self::run_security(&[
            "find-certificate",
            "-c",
            common_name,
            "-a",
            "-Z",
            "/Library/Keychains/System.keychain",
        ])?;
        Ok(if trusted {
            CertTrustStatus::Trusted
        } else {
            CertTrustStatus::NotTrusted
        })
    }
}
