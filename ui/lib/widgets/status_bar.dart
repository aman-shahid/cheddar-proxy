import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_notifier.dart';
import '../../core/models/traffic_state.dart';
import '../../core/utils/system_proxy_service.dart';

/// Status bar at the bottom of the app
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;
    final isMac = Platform.isMacOS;

    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    final padding = isMac
        ? const EdgeInsets.symmetric(horizontal: 18)
        : const EdgeInsets.symmetric(horizontal: 12);
    final barHeight = isMac ? 32.0 : 28.0;

    return Consumer<TrafficState>(
      builder: (context, state, _) {
        return Container(
          height: barHeight,
          padding: padding,
          decoration: BoxDecoration(
            color: surface,
            border: Border(top: BorderSide(color: borderColor)),
          ),
          child: Row(
            children: [
              // Recording indicator
              _StatusIndicator(
                isActive: state.isRecording,
                activeColor: AppColors.success,
                activeText: 'Recording',
                inactiveText: 'Paused',
                icon: state.isRecording
                    ? Icons.fiber_manual_record
                    : Icons.pause,
                onTap: state.toggleRecording,
                textMuted: textMuted,
              ),
              _StatusDivider(color: borderColor),

              // Proxy address / System Proxy indicator
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lan_outlined,
                    size: 14,
                    color: state.isRecording ? AppColors.success : textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    state.isRecording
                        ? 'System Proxy: ${state.proxyAddress}'
                        : 'Proxy: Off',
                    style: TextStyle(
                      color: state.isRecording
                          ? AppColors.success
                          : textSecondary,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),

              _StatusDivider(color: borderColor),

              // Request count / Selection info
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.swap_vert, size: 14, color: textMuted),
                  const SizedBox(width: 6),
                  Text(
                    state.selectedCount > 1
                        ? '${state.selectedCount} of ${state.totalCount} selected'
                        : '${state.totalCount} requests',
                    style: TextStyle(color: textSecondary, fontSize: 12),
                  ),
                ],
              ),

              const Spacer(),

              // Data transfer (bidirectional)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('↑', style: TextStyle(color: textMuted, fontSize: 12)),
                  const SizedBox(width: 3),
                  Text(
                    _formatBytes(state.totalUploadBytes),
                    style: TextStyle(
                      color: textSecondary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('↓', style: TextStyle(color: textMuted, fontSize: 12)),
                  const SizedBox(width: 3),
                  Text(
                    _formatBytes(state.totalDownloadBytes),
                    style: TextStyle(
                      color: textSecondary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),

              // Only show certificate warning if NOT trusted
              if (state.certStatus != CertificateStatus.trusted) ...[
                _StatusDivider(color: borderColor),
                _CertificateStatus(
                  status: state.certStatus,
                  storagePath: state.storagePath,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Format bytes as human-readable string
  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '${bytes}B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
    }
  }
}

/// Status indicator with dot and text
class _StatusIndicator extends StatelessWidget {
  final bool isActive;
  final Color activeColor;
  final String activeText;
  final String inactiveText;
  final IconData icon;
  final VoidCallback onTap;
  final Color textMuted;

  const _StatusIndicator({
    required this.isActive,
    required this.activeColor,
    required this.activeText,
    required this.inactiveText,
    required this.icon,
    required this.onTap,
    required this.textMuted,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: isActive ? activeColor : textMuted),
            const SizedBox(width: 6),
            Text(
              isActive ? activeText : inactiveText,
              style: TextStyle(
                color: isActive ? activeColor : textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Certificate status indicator (informational only)
class _CertificateStatus extends StatelessWidget {
  final CertificateStatus status;
  final String? storagePath;

  const _CertificateStatus({required this.status, this.storagePath});

  @override
  Widget build(BuildContext context) {
    final color = _certColor(status);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_certIcon(status), size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            _certLabel(status),
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  static IconData _certIcon(CertificateStatus status) {
    switch (status) {
      case CertificateStatus.notInstalled:
        return Icons.warning_amber;
      case CertificateStatus.mismatch:
        return Icons.warning_amber;
      case CertificateStatus.notTrusted:
        return Icons.security;
      case CertificateStatus.trusted:
        return Icons.verified_user;
    }
  }

  static Color _certColor(CertificateStatus status) {
    switch (status) {
      case CertificateStatus.notInstalled:
        return AppColors.clientError;
      case CertificateStatus.mismatch:
        return AppColors.redirect;
      case CertificateStatus.notTrusted:
        return AppColors.redirect;
      case CertificateStatus.trusted:
        return AppColors.success;
    }
  }

  static String _certLabel(CertificateStatus status) {
    switch (status) {
      case CertificateStatus.notInstalled:
        return 'CA: Not Installed';
      case CertificateStatus.mismatch:
        return 'CA: Mismatch';
      case CertificateStatus.notTrusted:
        return 'CA: Not Trusted';
      case CertificateStatus.trusted:
        return 'CA: Trusted';
    }
  }
}

/// Vertical divider for status bar
class _StatusDivider extends StatelessWidget {
  final Color color;

  const _StatusDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: color,
    );
  }
}
