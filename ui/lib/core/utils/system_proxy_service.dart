import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'logger_service.dart';

/// Certificate installation and trust status
enum CertificateStatus {
  notInstalled, // Certificate file doesn't exist
  notTrusted, // Installed but not trusted in keychain
  mismatch, // Installed/trusted cert does not match on-disk cert
  trusted, // Installed and trusted
}

typedef CertificateStatusProvider =
    Future<CertificateStatus> Function(String? storagePath);
typedef ProxyConfiguredProvider = Future<bool> Function(int port);
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

@visibleForTesting
enum TestPlatform { macos, windows, other }

class SystemProxyService {
  static const String caFileName = 'cheddar_proxy_ca.pem';
  static const String _caCommonName = 'Cheddar Proxy CA';
  @visibleForTesting
  static CertificateStatusProvider? testCertificateStatusProvider;
  @visibleForTesting
  static ProxyConfiguredProvider? testProxyConfiguredProvider;
  @visibleForTesting
  static ProcessRunner? testProcessRunner;
  @visibleForTesting
  static TestPlatform? platformOverride;

  static bool get _isMacOS {
    if (platformOverride == TestPlatform.macos) return true;
    if (platformOverride == TestPlatform.windows) return false;
    if (platformOverride == TestPlatform.other) return false;
    return Platform.isMacOS;
  }

  static bool get _isWindows {
    if (platformOverride == TestPlatform.windows) return true;
    if (platformOverride == TestPlatform.macos) return false;
    if (platformOverride == TestPlatform.other) return false;
    return Platform.isWindows;
  }

  static MethodChannel? _platformChannel;

  static MethodChannel _ensurePrimaryPlatformChannel() {
    _platformChannel ??= const MethodChannel('com.cheddarproxy/platform');
    return _platformChannel!;
  }

  @visibleForTesting
  static void setPlatformOverride(TestPlatform? platform) {
    platformOverride = platform;
  }

  @visibleForTesting
  static void setProcessRunnerForTesting(ProcessRunner runner) {
    testProcessRunner = runner;
  }

  @visibleForTesting
  static void resetProcessRunner() {
    testProcessRunner = null;
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) {
    if (testProcessRunner != null) {
      return testProcessRunner!(executable, arguments);
    }
    return Process.run(executable, arguments);
  }

  @visibleForTesting
  static void setTestOverrides({
    CertificateStatusProvider? certificateStatusProvider,
    ProxyConfiguredProvider? proxyConfiguredProvider,
  }) {
    testCertificateStatusProvider = certificateStatusProvider;
    testProxyConfiguredProvider = proxyConfiguredProvider;
  }

  @visibleForTesting
  static void resetTestOverrides() {
    testCertificateStatusProvider = null;
    testProxyConfiguredProvider = null;
  }

  /// Check if the system proxy is correctly configured for Cheddar Proxy
  static Future<bool> isProxyConfigured(int port) async {
    if (testProxyConfiguredProvider != null) {
      return testProxyConfiguredProvider!(port);
    }
    if (_isMacOS) {
      return _isProxyConfiguredMacOS(port);
    } else if (_isWindows) {
      return _isProxyConfiguredWindows(port);
    }
    return true; // Unsupported platforms
  }

  static Future<bool> _isProxyConfiguredMacOS(int port) async {
    try {
      final result = await _runProcess('networksetup', [
        '-getwebproxy',
        'Wi-Fi',
      ]);
      final secureResult = await _runProcess('networksetup', [
        '-getsecurewebproxy',
        'Wi-Fi',
      ]);

      return _parseOutputMacOS(result.stdout.toString(), port) &&
          _parseOutputMacOS(secureResult.stdout.toString(), port);
    } catch (e) {
      LoggerService.error('Failed to check system proxy: $e');
      return false;
    }
  }

  static Future<bool> _isProxyConfiguredWindows(int port) async {
    try {
      // Check Internet Options proxy via registry
      final psCommand =
          '''
\$enabled = (Get-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
\$server = (Get-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
if (\$enabled -eq 1 -and \$server -eq "127.0.0.1:$port") { exit 0 } else { exit 1 }
''';
      final result = await _runProcess('powershell', ['-Command', psCommand]);
      return result.exitCode == 0;
    } catch (e) {
      LoggerService.error('Failed to check Windows proxy: \$e');
      return false;
    }
  }

  /// Try to enable system proxy
  static Future<bool> enableSystemProxy(int port) async {
    if (_isMacOS) {
      return _enableSystemProxyMacOS(port);
    } else if (_isWindows) {
      return _enableSystemProxyWindows(port);
    }
    return false;
  }

  static Future<bool> _enableSystemProxyMacOS(int port) async {
    try {
      // Set HTTP proxy
      var result = await _runProcess('networksetup', [
        '-setwebproxy',
        'Wi-Fi',
        '127.0.0.1',
        port.toString(),
      ]);
      if (result.exitCode != 0) {
        LoggerService.error('Failed to set web proxy: ${result.stderr}');
        return false;
      }

      // Enable HTTP proxy
      result = await _runProcess('networksetup', [
        '-setwebproxystate',
        'Wi-Fi',
        'on',
      ]);
      if (result.exitCode != 0) {
        LoggerService.error('Failed to enable web proxy: ${result.stderr}');
        return false;
      }

      // Set HTTPS proxy
      result = await _runProcess('networksetup', [
        '-setsecurewebproxy',
        'Wi-Fi',
        '127.0.0.1',
        port.toString(),
      ]);
      if (result.exitCode != 0) {
        LoggerService.error('Failed to set secure web proxy: ${result.stderr}');
        return false;
      }

      // Enable HTTPS proxy
      result = await _runProcess('networksetup', [
        '-setsecurewebproxystate',
        'Wi-Fi',
        'on',
      ]);
      if (result.exitCode != 0) {
        LoggerService.error(
          'Failed to enable secure web proxy: ${result.stderr}',
        );
        return false;
      }

      LoggerService.info('System proxy enabled on port $port');
      return true;
    } catch (e) {
      LoggerService.error('Failed to set system proxy: $e');
      return false;
    }
  }

  static Future<bool> _enableSystemProxyWindows(int port) async {
    try {
      // First check if proxy is already configured correctly
      final alreadyConfigured = await _isProxyConfiguredWindows(port);
      if (alreadyConfigured) {
        LoggerService.info('Windows proxy already configured on port $port');
        return true;
      }

      // Build PowerShell command - use simple string to avoid escaping issues
      final psCommand =
          '''
Set-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" -Name ProxyEnable -Value 1
Set-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" -Name ProxyServer -Value "127.0.0.1:$port"
Set-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" -Name ProxyOverride -Value "<local>"
''';

      LoggerService.debug('Running proxy enable command...');
      final result = await _runProcess('powershell', ['-Command', psCommand]);

      if (result.exitCode == 0) {
        LoggerService.info('Windows system proxy enabled on port $port');
        return true;
      }

      LoggerService.error(
        'Failed to set Windows proxy: exit=${result.exitCode}, stderr=${result.stderr}',
      );
      return false;
    } catch (e) {
      LoggerService.error('Failed to set Windows proxy: $e');
      return false;
    }
  }

  /// Disable system proxy
  static Future<bool> disableSystemProxy() async {
    if (_isMacOS) {
      return _disableSystemProxyMacOS();
    } else if (_isWindows) {
      return _disableSystemProxyWindows();
    }
    return false;
  }

  static Future<bool> _disableSystemProxyMacOS() async {
    try {
      // Disable HTTP proxy
      var result = await _runProcess('networksetup', [
        '-setwebproxystate',
        'Wi-Fi',
        'off',
      ]);
      if (result.exitCode != 0) {
        LoggerService.error('Failed to disable web proxy: ${result.stderr}');
      }

      // Disable HTTPS proxy
      result = await _runProcess('networksetup', [
        '-setsecurewebproxystate',
        'Wi-Fi',
        'off',
      ]);
      if (result.exitCode != 0) {
        LoggerService.error(
          'Failed to disable secure web proxy: ${result.stderr}',
        );
      }

      LoggerService.info('System proxy disabled');
      return true;
    } catch (e) {
      LoggerService.error('Failed to disable system proxy: $e');
      return false;
    }
  }

  static Future<bool> _disableSystemProxyWindows() async {
    try {
      // Disable proxy via registry
      final psCommand =
          'Set-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" -Name ProxyEnable -Value 0';
      final result = await _runProcess('powershell', ['-Command', psCommand]);
      if (result.exitCode != 0) {
        LoggerService.error('Failed to reset Windows proxy: ${result.stderr}');
        return false;
      }
      LoggerService.info('Windows system proxy disabled');
      return true;
    } catch (e) {
      LoggerService.error('Failed to disable Windows proxy: $e');
      return false;
    }
  }

  static bool _parseOutputMacOS(String output, int port) {
    // Expected format:
    // Enabled: Yes
    // Server: 127.0.0.1
    // Port: 9090

    final lines = output.split('\n');
    bool enabled = false;
    bool correctServer = false;
    bool correctPort = false;

    for (final line in lines) {
      if (line.trim().startsWith('Enabled: Yes')) enabled = true;
      if (line.trim().contains('Server: 127.0.0.1')) correctServer = true;
      if (line.trim().contains('Port: $port')) correctPort = true;
    }

    return enabled && correctServer && correctPort;
  }

  /// Check if the Cheddar Proxy Root CA certificate is trusted
  static Future<bool> isCertificateTrusted() async {
    try {
      final status = await getCertificateStatus(null);
      return status == CertificateStatus.trusted;
    } catch (e) {
      LoggerService.error('Failed to check certificate trust: $e');
      return false;
    }
  }

  /// Get detailed certificate status (not installed, not trusted, or trusted)
  static Future<CertificateStatus> getCertificateStatus(
    String? storagePath,
  ) async {
    if (testCertificateStatusProvider != null) {
      return testCertificateStatusProvider!(storagePath);
    }
    if (_isMacOS) {
      return _getCertificateStatusMacOS(storagePath);
    } else if (_isWindows) {
      return _getCertificateStatusWindows(storagePath);
    }
    return CertificateStatus.trusted; // Unsupported platforms
  }

  static Future<CertificateStatus> _getCertificateStatusWindows(
    String? storagePath,
  ) async {
    String? diskFingerprint;
    if (storagePath != null) {
      final certPath = '$storagePath/$caFileName';
      final file = File(certPath);
      if (!await file.exists()) {
        LoggerService.warn('Certificate file does not exist: $certPath');
        return CertificateStatus.notInstalled;
      }
      diskFingerprint = await _sha256ForFile(certPath);
      if (diskFingerprint == null) {
        LoggerService.warn('Could not compute fingerprint for $certPath');
      }
    }

    // First check if the certificate file exists
    try {
      // Check if certificate is in Windows Root store (Local Machine)
      final result = await _runProcess('certutil', [
        '-store',
        'Root',
        'Cheddar Proxy CA',
      ]);

      if (result.exitCode == 0 &&
          result.stdout.toString().contains('Cheddar Proxy CA')) {
        LoggerService.info('Certificate found in Windows Root store');
        // Compare fingerprint if we have both
        final storeFingerprint = _parseCertutilSha256(result.stdout.toString());
        if (diskFingerprint != null &&
            storeFingerprint != null &&
            diskFingerprint.toLowerCase() != storeFingerprint.toLowerCase()) {
          LoggerService.warn(
            'Certificate fingerprint mismatch (disk vs Windows store)',
          );
          return CertificateStatus.mismatch;
        }
        return CertificateStatus.trusted;
      }

      LoggerService.warn('Certificate not found in Windows Root store');
      return CertificateStatus.notInstalled;
    } catch (e) {
      LoggerService.error('Failed to check Windows certificate: $e');
      return CertificateStatus.notInstalled;
    }
  }

  static Future<CertificateStatus> _getCertificateStatusMacOS(
    String? storagePath,
  ) async {
    String? diskFingerprint;
    String? keychainFingerprint;

    // First check if the certificate file exists
    if (storagePath != null) {
      final certPath = '$storagePath/cheddar_proxy_ca.pem';
      final file = File(certPath);
      if (!await file.exists()) {
        LoggerService.warn('Certificate file does not exist: $certPath');
        return CertificateStatus.notInstalled;
      }
      diskFingerprint = await _sha256ForFile(certPath);
      if (diskFingerprint == null) {
        LoggerService.warn('Could not compute fingerprint for $certPath');
      }
    }

    // Check if certificate is in keychain search list (login keychain included)
    try {
      final result = await _runProcess('security', [
        'find-certificate',
        '-c',
        'Cheddar Proxy CA',
      ]);

      if (result.exitCode != 0) {
        LoggerService.warn('Certificate not found in keychain search list');
        return CertificateStatus.notInstalled;
      }

      LoggerService.debug('Certificate found in keychain, checking trust...');

      final exportResult = await _runProcess('security', [
        'find-certificate',
        '-c',
        'Cheddar Proxy CA',
        '-p',
      ]);

      if (exportResult.exitCode == 0 &&
          exportResult.stdout.toString().contains('BEGIN CERTIFICATE')) {
        // Write to temp file and verify
        final tempFile = File('/tmp/cheddar_proxy_verify.pem');
        await tempFile.writeAsString(exportResult.stdout.toString());

        keychainFingerprint = await _sha256ForFile(tempFile.path);

        final verifyResult = await _runProcess('security', [
          'verify-cert',
          '-c',
          '/tmp/cheddar_proxy_verify.pem',
        ]);

        if (verifyResult.exitCode == 0) {
          if (diskFingerprint != null &&
              keychainFingerprint != null &&
              diskFingerprint.toLowerCase() !=
                  keychainFingerprint.toLowerCase()) {
            LoggerService.warn(
              'Certificate fingerprint mismatch (disk vs keychain)',
            );
            return CertificateStatus.mismatch;
          }
          LoggerService.info('Certificate is trusted (verify-cert succeeded)');
          return CertificateStatus.trusted;
        }
      }

      LoggerService.warn('Certificate in System keychain but not trusted');
      return CertificateStatus.notTrusted;
    } catch (e) {
      LoggerService.error('Failed to check certificate status: $e');
      return CertificateStatus.notInstalled;
    }
  }

  /// Compute SHA256 fingerprint for a PEM or DER file
  static Future<String?> _sha256ForFile(String path) async {
    try {
      // Use openssl if available
      final result = await _runProcess('openssl', [
        'x509',
        '-noout',
        '-fingerprint',
        '-sha256',
        '-in',
        path,
      ]);
      if (result.exitCode == 0) {
        final out = result.stdout.toString().trim();
        final parts = out.split('=');
        if (parts.length == 2) {
          return parts[1].replaceAll(':', '');
        }
      }
    } catch (_) {
      // Fall back to certutil on Windows
    }

    if (_isWindows) {
      try {
        final result = await _runProcess('certutil', [
          '-hashfile',
          path,
          'SHA256',
        ]);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().split('\n');
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || trimmed.startsWith('CertUtil')) continue;
            // first non-empty line after header is the hash
            return trimmed.replaceAll(' ', '');
          }
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static String? _parseCertutilSha256(String stdout) {
    final lines = stdout.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.toLowerCase().startsWith('sha256 hash')) {
        // Next line should contain the hash
        final idx = lines.indexOf(line);
        if (idx + 1 < lines.length) {
          return lines[idx + 1].trim().replaceAll(' ', '');
        }
      }
    }
    return null;
  }

  /// Trust and import the certificate to system certificate store
  /// Note: Requires admin approval on both macOS and Windows
  static Future<bool> trustAndImportCertificate(String certPath) async {
    if (_isMacOS) {
      return _trustAndImportCertificateMacOS(certPath);
    } else if (_isWindows) {
      return _trustAndImportCertificateWindows(certPath);
    }
    LoggerService.warn('trustAndImportCertificate is not supported on this OS');
    return false;
  }

  static Future<bool> installCertificateToLoginKeychain(String certPath) async {
    if (_isMacOS) {
      return _installCertificateIntoLoginKeychain(certPath);
    }
    return true;
  }

  /// Remove existing Cheddar Proxy CA from system stores (best effort)
  static Future<void> removeExistingCertificate() async {
    try {
      if (_isMacOS) {
        await _runProcess('security', [
          'delete-certificate',
          '-c',
          _caCommonName,
        ]);
      } else if (_isWindows) {
        await _runProcess('certutil', ['-delstore', 'Root', _caCommonName]);
      }
    } catch (e) {
      LoggerService.warn('Failed to remove existing certificate: $e');
    }
  }

  static Future<bool> _trustAndImportCertificateWindows(String certPath) async {
    // Check if file exists first
    final file = File(certPath);
    if (!await file.exists()) {
      LoggerService.warn('Certificate file does not exist: $certPath');
      return false;
    }

    try {
      LoggerService.info('Installing certificate to Windows Root store...');

      // Use PowerShell to run certutil with elevation
      // The -addstore Root command adds to the Trusted Root CA store
      final escapedPath = certPath.replaceAll('\\', '\\\\');
      final result = await _runProcess('powershell', [
        '-Command',
        'Start-Process certutil -ArgumentList \'-addstore\',\'Root\',\'"$escapedPath"\' -Verb RunAs -Wait',
      ]);

      if (result.exitCode == 0) {
        LoggerService.info('Certificate installed to Windows Root store');
        return true;
      }

      LoggerService.error('Failed to install certificate: ${result.stderr}');
      return false;
    } catch (e) {
      LoggerService.error('Failed to install Windows certificate: $e');
      return false;
    }
  }

  static Future<bool> _trustAndImportCertificateMacOS(String certPath) async {
    // Check if file exists first
    final file = File(certPath);
    if (!await file.exists()) {
      LoggerService.warn('Certificate file does not exist: $certPath');
      return false;
    }

    try {
      LoggerService.info('Promoting certificate trust via native helper...');
      final commonName = await _determineCertificateCommonName(certPath);
      final channel = _ensurePrimaryPlatformChannel();
      final result = await channel.invokeMethod<bool>('trustMacCertificate', {
        'commonName': commonName,
      });
      if (result == true) {
        LoggerService.info('Certificate trusted in login keychain.');
        return true;
      }

      LoggerService.error(
        'Native trust helper failed, opening certificate manually.',
      );
      await _runProcess('open', ['-a', 'Keychain Access', certPath]);
      return false;
    } on MissingPluginException catch (e) {
      LoggerService.warn(
        'Native trust channel unavailable (${e.message}); falling back to Swift helper...',
      );
      final commonName = await _determineCertificateCommonName(certPath);
      final fallbackSuccess = await _trustCertificateViaSwiftHelper(commonName);
      if (fallbackSuccess) {
        LoggerService.info('Certificate trusted via Swift helper.');
        return true;
      }
      LoggerService.error('Swift helper failed, opening certificate manually.');
      await _runProcess('open', ['-a', 'Keychain Access', certPath]);
      return false;
    } on PlatformException catch (e) {
      LoggerService.error('Native trust helper error: ${e.message}');
      await _runProcess('open', ['-a', 'Keychain Access', certPath]);
      return false;
    } catch (e) {
      LoggerService.error('Failed to invoke native trust helper: $e');
      await _runProcess('open', ['-a', 'Keychain Access', certPath]);
      return false;
    }
  }

  static Future<bool> _installCertificateIntoLoginKeychain(
    String certPath,
  ) async {
    try {
      final homeDir = Platform.environment['HOME'];
      if (homeDir == null || homeDir.isEmpty) {
        LoggerService.error('HOME directory not set; cannot locate keychain.');
        return false;
      }

      final loginKeychain = '$homeDir/Library/Keychains/login.keychain-db';
      final result = await _runProcess('/usr/bin/security', [
        'add-certificates',
        '-k',
        loginKeychain,
        certPath,
      ]);

      if (result.exitCode == 0) {
        LoggerService.info('Certificate added to login keychain.');
        return true;
      }
      final stderr = result.stderr.toString();
      if (_isDuplicateCertMessage(stderr)) {
        LoggerService.info('Certificate already exists in login keychain.');
        return true;
      }

      LoggerService.warn(
        'Failed to add certificate to login keychain (exit=${result.exitCode}): '
        '${stderr.isEmpty ? result.stdout : stderr}',
      );
      return false;
    } catch (e) {
      LoggerService.error(
        'Exception while adding certificate to login keychain: $e',
      );
      return false;
    }
  }

  static bool _isDuplicateCertMessage(String stderr) {
    final normalized = stderr.toLowerCase();
    return normalized.contains('already exists in the keychain') ||
        normalized.contains('already in') ||
        normalized.contains('duplicate item');
  }

  static Future<String> _determineCertificateCommonName(String certPath) async {
    try {
      final result = await _runProcess('/usr/bin/openssl', [
        'x509',
        '-noout',
        '-subject',
        '-in',
        certPath,
      ]);
      if (result.exitCode == 0) {
        final subject = result.stdout.toString();
        final match = RegExp(r'CN=([^/\\n]+)').firstMatch(subject);
        if (match != null) {
          return match.group(1)!.trim();
        }
      }
    } catch (_) {
      // ignore and fall back
    }
    return 'Cheddar Proxy CA';
  }

  static Future<bool> _trustCertificateViaSwiftHelper(String commonName) async {
    final script = '''
import Foundation
import Security

let commonName = CommandLine.arguments[1]

let query: [CFString: Any] = [
  kSecClass: kSecClassCertificate,
  kSecMatchLimit: kSecMatchLimitOne,
  kSecReturnRef: true,
  kSecAttrLabel: commonName,
  kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
]

var item: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &item)
guard status == errSecSuccess, let certificate = item else {
  fputs("cert_not_found:\\(status)\\n", stderr)
  exit(1)
}

let trustSettings = [
  [
    kSecTrustSettingsResult: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue)
  ]
] as CFArray

let result = SecTrustSettingsSetTrustSettings(
  certificate as! SecCertificate,
  SecTrustSettingsDomain.user,
  trustSettings
)

if result == errSecSuccess {
  exit(0)
} else {
  fputs("trust_failed:\\(result)\\n", stderr)
  exit(2)
}
''';

    final tempDir = Directory.systemTemp;
    final scriptFile = File('${tempDir.path}/cheddar_trust_helper.swift');
    await scriptFile.writeAsString(script);

    final processResult = await _runProcess('xcrun', [
      'swift',
      scriptFile.path,
      commonName,
    ]);

    if (processResult.exitCode == 0) {
      return true;
    }

    LoggerService.error(
      'Swift trust helper failed (exit=${processResult.exitCode}): '
      '${processResult.stderr}',
    );
    return false;
  }

  /// Open the system certificate manager for viewing
  static Future<bool> viewCertificateInKeychain() async {
    if (_isMacOS) {
      try {
        final result = await _runProcess('open', ['-a', 'Keychain Access']);
        return result.exitCode == 0;
      } catch (e) {
        LoggerService.error('Failed to open Keychain Access: $e');
        return false;
      }
    } else if (_isWindows) {
      try {
        // Open Windows Certificate Manager
        final result = await _runProcess('certmgr.msc', []);
        return result.exitCode == 0;
      } catch (e) {
        LoggerService.error('Failed to open Certificate Manager: $e');
        return false;
      }
    }
    return false;
  }

  /// Open the certificate file for viewing
  static Future<bool> viewCertificateFile(String certPath) async {
    try {
      if (_isMacOS) {
        final result = await _runProcess('open', [certPath]);
        return result.exitCode == 0;
      } else if (_isWindows) {
        // Windows uses 'start' to open files with default app
        final result = await _runProcess('cmd', ['/c', 'start', '', certPath]);
        return result.exitCode == 0;
      }
      return false;
    } catch (e) {
      LoggerService.error('Failed to view certificate file: $e');
      return false;
    }
  }

  /// Save/export the certificate to a user-specified location
  static Future<bool> saveCertificateTo(
    String sourcePath,
    String destinationPath,
  ) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        LoggerService.warn('Source certificate not found: $sourcePath');
        return false;
      }
      await sourceFile.copy(destinationPath);
      LoggerService.info('Certificate saved to: $destinationPath');
      return true;
    } catch (e) {
      LoggerService.error('Failed to save certificate: $e');
      return false;
    }
  }

  /// Parse certificate details from PEM file for display
  static Future<CertificateInfo?> getCertificateInfo(String certPath) async {
    try {
      final file = File(certPath);
      if (!await file.exists()) {
        return null;
      }

      // Use openssl to parse the certificate
      final result = await _runProcess('openssl', [
        'x509',
        '-in',
        certPath,
        '-noout',
        '-subject',
        '-issuer',
        '-dates',
        '-fingerprint',
        '-sha256',
      ]);

      if (result.exitCode != 0) {
        LoggerService.error('Failed to parse certificate: ${result.stderr}');
        return null;
      }

      final output = result.stdout.toString();
      return CertificateInfo.fromOpenSSLOutput(output);
    } catch (e) {
      LoggerService.error('Failed to get certificate info: $e');
      return null;
    }
  }
}

/// Certificate information parsed from PEM file
class CertificateInfo {
  final String subject;
  final String issuer;
  final String notBefore;
  final String notAfter;
  final String fingerprint;

  CertificateInfo({
    required this.subject,
    required this.issuer,
    required this.notBefore,
    required this.notAfter,
    required this.fingerprint,
  });

  factory CertificateInfo.fromOpenSSLOutput(String output) {
    String subject = 'Unknown';
    String issuer = 'Unknown';
    String notBefore = 'Unknown';
    String notAfter = 'Unknown';
    String fingerprint = 'Unknown';

    for (final line in output.split('\n')) {
      if (line.startsWith('subject=')) {
        // Extract CN from subject
        final cnMatch = RegExp(r'CN\s*=\s*([^,/]+)').firstMatch(line);
        subject = cnMatch?.group(1)?.trim() ?? line.substring(8);
      } else if (line.startsWith('issuer=')) {
        final cnMatch = RegExp(r'CN\s*=\s*([^,/]+)').firstMatch(line);
        issuer = cnMatch?.group(1)?.trim() ?? line.substring(7);
      } else if (line.startsWith('notBefore=')) {
        notBefore = line.substring(10).trim();
      } else if (line.startsWith('notAfter=')) {
        notAfter = line.substring(9).trim();
      } else if (line.contains('Fingerprint=')) {
        fingerprint = line.split('=').last.trim();
      }
    }

    return CertificateInfo(
      subject: subject,
      issuer: issuer,
      notBefore: notBefore,
      notAfter: notAfter,
      fingerprint: fingerprint,
    );
  }

  /// Get a shortened fingerprint for display
  String get shortFingerprint {
    if (fingerprint.length > 23) {
      return '${fingerprint.substring(0, 23)}...';
    }
    return fingerprint;
  }
}
