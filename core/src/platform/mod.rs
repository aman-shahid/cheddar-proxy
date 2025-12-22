//! Platform-specific adapters for proxy configuration and certificate trust.

use anyhow::Result;
use flutter_rust_bridge::frb;

#[cfg(target_os = "macos")]
mod mac;
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
mod noop;
#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "macos")]
use mac::MacProxyAdapter as PlatformImpl;
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
use noop::NoopProxyAdapter as PlatformImpl;
#[cfg(target_os = "windows")]
use windows::WindowsProxyAdapter as PlatformImpl;

static ADAPTER: PlatformImpl = PlatformImpl::new();

pub trait PlatformProxyAdapter: Sync + Send {
    fn enable_system_proxy(&self, host: &str, port: u16) -> Result<()>;
    fn disable_system_proxy(&self) -> Result<()>;
    fn detect_certificate_trust(&self, common_name: &str) -> Result<CertTrustStatus>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[frb]
pub enum CertTrustStatus {
    Unknown,
    Trusted,
    NotTrusted,
}

pub fn enable_system_proxy(host: &str, port: u16) -> Result<()> {
    ADAPTER.enable_system_proxy(host, port)
}

pub fn disable_system_proxy() -> Result<()> {
    ADAPTER.disable_system_proxy()
}

pub fn detect_certificate_trust(common_name: &str) -> Result<CertTrustStatus> {
    ADAPTER.detect_certificate_trust(common_name)
}
