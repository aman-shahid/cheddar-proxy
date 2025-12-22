import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Information about an available update
class UpdateInfo {
  final String version;
  final String releaseNotes;
  final String? windowsDownloadUrl;
  final String? macosDownloadUrl;
  final String releaseUrl;
  final DateTime publishedAt;

  UpdateInfo({
    required this.version,
    required this.releaseNotes,
    required this.releaseUrl,
    required this.publishedAt,
    this.windowsDownloadUrl,
    this.macosDownloadUrl,
  });

  /// Get the download URL for the current platform
  String? get downloadUrl {
    if (Platform.isWindows) return windowsDownloadUrl;
    if (Platform.isMacOS) return macosDownloadUrl;
    return null;
  }
}

/// Service to check for application updates via GitHub Releases
class UpdateService {
  static const String _owner = 'aman-shahid';
  static const String _repo = 'cheddarproxy';
  static const String _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// Check for available updates
  /// Returns [UpdateInfo] if an update is available, null otherwise
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final response = await http
          .get(
            Uri.parse(_apiUrl),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return null;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;

      // Get version from tag (strip 'v' prefix if present)
      final tagName = data['tag_name'] as String? ?? '';
      final latestVersion = tagName.startsWith('v')
          ? tagName.substring(1)
          : tagName;

      // Compare versions
      if (!_isNewerVersion(latestVersion, currentVersion)) {
        return null;
      }

      // Parse assets for download URLs
      String? windowsUrl;
      String? macosUrl;

      final assets = data['assets'] as List<dynamic>? ?? [];
      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        final downloadUrl = asset['browser_download_url'] as String?;

        if (downloadUrl != null) {
          if (name.endsWith('.exe') ||
              name.endsWith('.msix') ||
              name.contains('windows')) {
            windowsUrl = downloadUrl;
          } else if (name.endsWith('.dmg') ||
              name.endsWith('.pkg') ||
              name.contains('macos')) {
            macosUrl = downloadUrl;
          }
        }
      }

      return UpdateInfo(
        version: latestVersion,
        releaseNotes: data['body'] as String? ?? 'No release notes available.',
        releaseUrl:
            data['html_url'] as String? ??
            'https://github.com/$_owner/$_repo/releases/latest',
        publishedAt:
            DateTime.tryParse(data['published_at'] as String? ?? '') ??
            DateTime.now(),
        windowsDownloadUrl: windowsUrl,
        macosDownloadUrl: macosUrl,
      );
    } catch (e) {
      // Silently fail - don't block app startup for update check failures
      return null;
    }
  }

  /// Compare semantic versions
  /// Returns true if [latest] is newer than [current]
  static bool _isNewerVersion(String latest, String current) {
    try {
      final latestParts = latest.split('.').map(int.parse).toList();
      final currentParts = current.split('.').map(int.parse).toList();

      // Pad with zeros if needed
      while (latestParts.length < 3) {
        latestParts.add(0);
      }
      while (currentParts.length < 3) {
        currentParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
