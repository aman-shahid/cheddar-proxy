use super::{CertTrustStatus, PlatformProxyAdapter};
use anyhow::{anyhow, Result};

pub struct NoopProxyAdapter;

impl NoopProxyAdapter {
    pub const fn new() -> Self {
        Self
    }
}

impl PlatformProxyAdapter for NoopProxyAdapter {
    fn enable_system_proxy(&self, _host: &str, _port: u16) -> Result<()> {
        Err(anyhow!(
            "System proxy configuration unsupported on this platform"
        ))
    }

    fn disable_system_proxy(&self) -> Result<()> {
        Err(anyhow!(
            "System proxy configuration unsupported on this platform"
        ))
    }

    fn detect_certificate_trust(&self, _common_name: &str) -> Result<CertTrustStatus> {
        Ok(CertTrustStatus::Unknown)
    }
}
