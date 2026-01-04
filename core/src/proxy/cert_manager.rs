use anyhow::{anyhow, Context};
use rcgen::{
    BasicConstraints, Certificate, CertificateParams, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, Ia5String, IsCa, KeyPair, KeyUsagePurpose, SanType,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::server::ServerConfig;
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use time::{Duration, OffsetDateTime};

const MAX_SERVER_CONFIG_CACHE: usize = 256;

pub struct CertManager {
    _storage_path: PathBuf,
    pub ca_cert_pem: String,
    ca_cert: Certificate,
    ca_key: KeyPair,
    ca_chain: Vec<CertificateDer<'static>>,
    server_configs: Mutex<ServerConfigCache>,
}

impl CertManager {
    /// Initialize CertManager, loading existing CA or generating a new one
    pub fn new(storage_path: &str) -> anyhow::Result<Self> {
        let path = Path::new(storage_path);
        let ca_cert_path = path.join("cheddar_proxy_ca.pem");
        let ca_key_path = path.join("cheddar_proxy_ca.key");

        let (ca_cert, ca_key, ca_cert_pem) = if ca_cert_path.exists() && ca_key_path.exists() {
            let ca_cert_pem =
                fs::read_to_string(&ca_cert_path).context("Failed to read CA certificate file")?;
            let ca_key_pem =
                fs::read_to_string(&ca_key_path).context("Failed to read CA key file")?;

            let ca_key = KeyPair::from_pem(&ca_key_pem).context("Failed to parse CA key")?;
            let params =
                CertificateParams::from_ca_cert_pem(&ca_cert_pem).context("Invalid CA PEM")?;
            let ca_cert = params
                .self_signed(&ca_key)
                .context("Failed to reconstruct CA certificate")?;

            (ca_cert, ca_key, ca_cert_pem)
        } else {
            let (ca_cert, ca_key) = Self::generate_root();
            let ca_cert_pem = ca_cert.pem();
            let ca_key_pem = ca_key.serialize_pem();

            if !path.exists() {
                fs::create_dir_all(path).context("Failed to create cert storage directory")?;
            }

            fs::write(&ca_cert_path, &ca_cert_pem).context("Failed to write CA certificate")?;
            fs::write(&ca_key_path, &ca_key_pem).context("Failed to write CA key")?;

            (ca_cert, ca_key, ca_cert_pem)
        };

        let ca_chain = vec![ca_cert.der().clone()];

        Ok(Self {
            _storage_path: path.to_path_buf(),
            ca_cert_pem,
            ca_cert,
            ca_key,
            ca_chain,
            server_configs: Mutex::new(ServerConfigCache::new()),
        })
    }

    fn generate_root() -> (Certificate, KeyPair) {
        // Get hostname for certificate identification
        let hostname = gethostname::gethostname().to_string_lossy().to_string();

        // Get current date for generation timestamp
        let now = OffsetDateTime::now_utc();
        let date_str = format!(
            "{:04}-{:02}-{:02}",
            now.year(),
            now.month() as u8,
            now.day()
        );

        // Create a descriptive Common Name with hostname and generation date
        let common_name = format!("Cheddar Proxy CA ({}, {})", hostname, date_str);

        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, common_name);
        dn.push(DnType::OrganizationName, "Cheddar Proxy");

        let mut params = CertificateParams::default();
        params.distinguished_name = dn;
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];

        let now = OffsetDateTime::now_utc();
        params.not_before = now.checked_sub(Duration::hours(1)).unwrap_or(now);
        params.not_after = now.checked_add(Duration::days(365 * 10)).unwrap_or(now);

        let key_pair = KeyPair::generate().expect("failed to generate CA key");
        let cert = params
            .self_signed(&key_pair)
            .expect("failed to self-sign CA certificate");
        (cert, key_pair)
    }

    pub fn server_config_for_host(&self, host: &str) -> anyhow::Result<Arc<ServerConfig>> {
        let cache_key = host.to_ascii_lowercase();
        {
            let mut cache = self
                .server_configs
                .lock()
                .map_err(|_| anyhow!("CertManager cache poisoned"))?;
            if let Some(cfg) = cache.get(&cache_key) {
                return Ok(cfg);
            }
        }

        let (cert_chain, key_der) = self.issue_leaf_cert(host)?;

        let mut config = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(cert_chain, key_der)
            .context("Failed to build TLS server config")?;

        // Advertise HTTP/2 and HTTP/1.1 to clients
        config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

        let arc = Arc::new(config);
        let mut cache = self
            .server_configs
            .lock()
            .map_err(|_| anyhow!("CertManager cache poisoned"))?;
        cache.insert(cache_key, arc.clone());
        Ok(arc)
    }

    fn issue_leaf_cert(
        &self,
        host: &str,
    ) -> anyhow::Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
        let mut params = CertificateParams::default();

        // Handle SANs (IP or DNS)
        if let Ok(ip) = IpAddr::from_str(host) {
            params.subject_alt_names = vec![SanType::IpAddress(ip)];
        } else {
            params.subject_alt_names = vec![SanType::DnsName(
                Ia5String::try_from(host)
                    .map_err(|_| anyhow!("Invalid hostname for certificate"))?,
            )];
        }

        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, host);
        dn.push(DnType::OrganizationName, "Cheddar Proxy Intercepted");
        params.distinguished_name = dn;
        params.key_usages = vec![
            KeyUsagePurpose::DigitalSignature,
            KeyUsagePurpose::KeyEncipherment,
        ];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];

        // Leaf certs must be valid for <= 398 days for Apple devices (Public Trusted).
        // Since this is a locally trusted Root, we can try 3 years as requested (User asked for 3-10).
        // Backdate by 1 hour to allow for clock skew.
        let now = OffsetDateTime::now_utc();
        params.not_before = now.checked_sub(Duration::hours(1)).unwrap_or(now);
        params.not_after = now.checked_add(Duration::days(365 * 3)).unwrap_or(now);

        let key_pair = KeyPair::generate().context("Failed to generate leaf key")?;
        let cert = params
            .signed_by(&key_pair, &self.ca_cert, &self.ca_key)
            .context("Failed to sign leaf certificate")?;

        let mut chain = Vec::with_capacity(2);
        chain.push(cert.der().clone());
        chain.extend(self.ca_chain.iter().cloned());

        let key = PrivateKeyDer::from(PrivatePkcs8KeyDer::from(key_pair.serialize_der()));
        Ok((chain, key.clone_key()))
    }

    #[cfg(test)]
    pub fn test_ca_der(&self) -> CertificateDer<'static> {
        self.ca_cert.der().clone()
    }
}

struct ServerConfigCache {
    map: HashMap<String, Arc<ServerConfig>>,
    order: VecDeque<String>,
}

impl ServerConfigCache {
    fn new() -> Self {
        Self {
            map: HashMap::new(),
            order: VecDeque::new(),
        }
    }

    fn get(&mut self, key: &str) -> Option<Arc<ServerConfig>> {
        if let Some(cfg) = self.map.get(key) {
            let cfg = cfg.clone();
            self.promote(key);
            Some(cfg)
        } else {
            None
        }
    }

    fn insert(&mut self, key: String, config: Arc<ServerConfig>) {
        self.map.insert(key.clone(), config);
        self.promote(&key);
        self.evict();
    }

    fn promote(&mut self, key: &str) {
        if let Some(pos) = self.order.iter().position(|k| k == key) {
            self.order.remove(pos);
        }
        self.order.push_back(key.to_string());
    }

    fn evict(&mut self) {
        while self.order.len() > MAX_SERVER_CONFIG_CACHE {
            if let Some(oldest) = self.order.pop_front() {
                self.map.remove(&oldest);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn generates_ca_once_and_reuses_existing_files() {
        let dir = tempdir().unwrap();
        let path = dir.path().to_string_lossy().to_string();

        {
            let manager = CertManager::new(&path).expect("initial creation");
            assert!(!manager.ca_cert_pem.is_empty());
            let cert_path = dir.path().join("cheddar_proxy_ca.pem");
            assert!(cert_path.exists());
        }

        // Modify the PEM file to detect reuse
        let cert_path = dir.path().join("cheddar_proxy_ca.pem");
        let original_pem = fs::read_to_string(&cert_path).unwrap();

        let manager_again = CertManager::new(&path).expect("reuse existing");
        assert_eq!(manager_again.ca_cert_pem, original_pem);
    }
}
