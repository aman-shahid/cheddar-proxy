use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
#[cfg(target_os = "macos")]
use std::process::Command;

#[cfg(any(target_os = "macos", target_os = "windows"))]
use anyhow::anyhow;
use anyhow::Result;
#[cfg(target_os = "macos")]
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
#[cfg(target_os = "macos")]
use base64::Engine as _;
use uuid::Uuid;
#[cfg(target_os = "windows")]
use windows_sys::Win32::Foundation::{GetLastError, LocalFree};
#[cfg(target_os = "windows")]
use windows_sys::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPTPROTECT_LOCAL_MACHINE,
    CRYPT_INTEGER_BLOB as DATA_BLOB,
};
const TOKEN_FILE_NAME: &str = "mcp_token.secret";
#[cfg(target_os = "macos")]
const MAC_KEYCHAIN_SERVICE: &str = "com.cheddarproxy.mcp";

#[derive(Clone)]
pub struct McpAuthTokenManager {
    storage_path: PathBuf,
}

impl McpAuthTokenManager {
    pub fn new(storage_path: PathBuf) -> Self {
        Self { storage_path }
    }

    pub fn ensure_token(&self) -> Result<String> {
        if let Some(token) = self.read_token()? {
            return Ok(token);
        }
        let token = Self::generate_token();
        self.store_token(&token)?;
        Ok(token)
    }

    pub fn regenerate_token(&self) -> Result<String> {
        let token = Self::generate_token();
        self.store_token(&token)?;
        Ok(token)
    }

    pub fn verify_token(&self, candidate: &str) -> Result<bool> {
        if let Some(expected) = self.read_token()? {
            Ok(constant_time_eq(&expected, candidate))
        } else {
            Ok(false)
        }
    }

    pub fn read_token(&self) -> Result<Option<String>> {
        #[cfg(target_os = "macos")]
        {
            if let Some(token) = self.read_from_keychain()? {
                Ok(Some(token))
            } else {
                self.read_plain_file()
            }
        }

        #[cfg(target_os = "windows")]
        {
            if let Some(token) = self.read_encrypted_file()? {
                Ok(Some(token))
            } else {
                // Fallback to plaintext if decryption fails or file missing
                self.read_plain_file()
            }
        }

        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            self.read_plain_file()
        }
    }

    fn store_token(&self, token: &str) -> Result<()> {
        #[cfg(target_os = "macos")]
        {
            if let Err(err) = self.write_to_keychain(token) {
                tracing::warn!("Failed to store MCP token in Keychain: {err}");
                self.write_plain_file(token)?;
            } else {
                // Remove fallback file if it exists
                let _ = fs::remove_file(self.secret_path());
            }
            Ok(())
        }

        #[cfg(target_os = "windows")]
        {
            // Prefer DPAPI-encrypted storage on Windows; fall back to plaintext on error.
            if let Err(err) = self.write_encrypted_file(token) {
                tracing::warn!("Failed to protect MCP token with DPAPI: {err}");
                self.write_plain_file(token)?;
            }
            Ok(())
        }

        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            self.write_plain_file(token)?;
            Ok(())
        }
    }

    fn secret_path(&self) -> PathBuf {
        self.storage_path.join(TOKEN_FILE_NAME)
    }

    fn generate_token() -> String {
        Uuid::new_v4().to_string().replace('-', "")
    }

    #[cfg(target_os = "macos")]
    fn account_name(&self) -> String {
        let encoded = URL_SAFE_NO_PAD.encode(self.storage_path.to_string_lossy().as_bytes());
        format!("cheddarproxy-{encoded}")
    }

    #[cfg(target_os = "macos")]
    fn write_to_keychain(&self, token: &str) -> Result<()> {
        let account = self.account_name();
        let status = Command::new("security")
            .args([
                "add-generic-password",
                "-a",
                &account,
                "-s",
                MAC_KEYCHAIN_SERVICE,
                "-w",
                token,
                "-U",
            ])
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(anyhow!("security command failed with status {}", status))
        }
    }

    #[cfg(target_os = "macos")]
    fn read_from_keychain(&self) -> Result<Option<String>> {
        let account = self.account_name();
        let output = Command::new("security")
            .args([
                "find-generic-password",
                "-a",
                &account,
                "-s",
                MAC_KEYCHAIN_SERVICE,
                "-w",
            ])
            .output()?;
        if output.status.success() {
            let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if token.is_empty() {
                Ok(None)
            } else {
                Ok(Some(token))
            }
        } else if String::from_utf8_lossy(&output.stderr).contains("could not be found") {
            Ok(None)
        } else {
            Err(anyhow!(
                "security find-generic-password failed: {}",
                String::from_utf8_lossy(&output.stderr)
            ))
        }
    }

    fn write_plain_file(&self, token: &str) -> Result<()> {
        fs::create_dir_all(&self.storage_path)?;
        let path = self.secret_path();
        let mut file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        }
        file.write_all(token.as_bytes())?;
        Ok(())
    }

    fn read_plain_file(&self) -> Result<Option<String>> {
        let path = self.secret_path();
        if !path.exists() {
            return Ok(None);
        }
        let mut file = fs::File::open(path)?;
        let mut contents = String::new();
        file.read_to_string(&mut contents)?;
        let trimmed = contents.trim();
        if trimmed.is_empty() {
            Ok(None)
        } else {
            Ok(Some(trimmed.to_string()))
        }
    }

    #[cfg(target_os = "windows")]
    fn write_encrypted_file(&self, token: &str) -> Result<()> {
        let encrypted = dpapi_protect(token.as_bytes())?;
        fs::create_dir_all(&self.storage_path)?;
        let path = self.secret_path();
        let mut file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&path)?;
        file.write_all(&encrypted)?;
        Ok(())
    }

    #[cfg(target_os = "windows")]
    fn read_encrypted_file(&self) -> Result<Option<String>> {
        let path = self.secret_path();
        if !path.exists() {
            return Ok(None);
        }
        let mut buf = Vec::new();
        fs::File::open(&path)?.read_to_end(&mut buf)?;
        if buf.is_empty() {
            return Ok(None);
        }
        let decrypted = dpapi_unprotect(&buf)?;
        let token = String::from_utf8_lossy(&decrypted).trim().to_string();
        if token.is_empty() {
            Ok(None)
        } else {
            Ok(Some(token))
        }
    }
}

impl From<&Path> for McpAuthTokenManager {
    fn from(path: &Path) -> Self {
        Self {
            storage_path: path.to_path_buf(),
        }
    }
}

fn constant_time_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.as_bytes().iter().zip(b.as_bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(target_os = "windows")]
fn dpapi_protect(data: &[u8]) -> Result<Vec<u8>> {
    unsafe {
        let mut in_blob = DATA_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr() as *mut u8,
        };
        let mut out_blob = DATA_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };

        let ok = CryptProtectData(
            &mut in_blob,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            CRYPTPROTECT_LOCAL_MACHINE,
            &mut out_blob,
        );
        if ok == 0 {
            let err = GetLastError();
            return Err(anyhow!(
                "CryptProtectData failed: {}",
                std::io::Error::from_raw_os_error(err as i32)
            ));
        }

        let slice = std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize);
        let mut result = Vec::with_capacity(slice.len());
        result.extend_from_slice(slice);
        LocalFree(out_blob.pbData as *mut _);
        Ok(result)
    }
}

#[cfg(target_os = "windows")]
fn dpapi_unprotect(data: &[u8]) -> Result<Vec<u8>> {
    unsafe {
        let mut in_blob = DATA_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr() as *mut u8,
        };
        let mut out_blob = DATA_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };

        let ok = CryptUnprotectData(
            &mut in_blob,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
            &mut out_blob,
        );
        if ok == 0 {
            let err = GetLastError();
            return Err(anyhow!(
                "CryptUnprotectData failed: {}",
                std::io::Error::from_raw_os_error(err as i32)
            ));
        }

        let slice = std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize);
        let mut result = Vec::with_capacity(slice.len());
        result.extend_from_slice(slice);
        LocalFree(out_blob.pbData as *mut _);
        Ok(result)
    }
}
