import 'dart:io';

import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../core/models/traffic_state.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_notifier.dart';

/// About dialog showing app information
class CheddarProxyAboutDialog extends StatelessWidget {
  const CheddarProxyAboutDialog({super.key});

  static Future<void> show(BuildContext context) {
    if (Platform.isMacOS) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final macTheme = MacosThemeData(
        brightness: isDark ? Brightness.dark : Brightness.light,
      );
      return showDialog(
        context: context,
        builder: (_) =>
            MacosTheme(data: macTheme, child: const _MacAboutDialog()),
      );
    }

    if (Platform.isWindows) {
      return showDialog(
        context: context,
        builder: (_) => const _WindowsAboutDialog(),
      );
    }

    // Fallback for Linux and other platforms
    return showDialog(
      context: context,
      builder: (_) => const CheddarProxyAboutDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;

    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;

    return Dialog(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor),
      ),
      child: const _AboutContent(
        showCloseButton: true,
        showIcon: true,
        width: 400,
        padding: EdgeInsets.all(24),
      ),
    );
  }
}

/// Windows-styled About dialog using Fluent UI design language
class _WindowsAboutDialog extends StatelessWidget {
  const _WindowsAboutDialog();

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;

    final backgroundColor = isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, minHeight: 300),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(
              8,
            ), // Windows uses less rounded corners
            border: Border.all(color: borderColor, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.2),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // App Icon
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/icon/window_icon.png',
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Cheddar Proxy',
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _AboutContent(
                  showCloseButton: false,
                  showIcon: false,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  compact: true,
                ),
                const SizedBox(height: 20),
                // Windows-style button
                SizedBox(
                  width: 100,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MacAboutDialog extends StatelessWidget {
  const _MacAboutDialog();

  @override
  Widget build(BuildContext context) {
    final macTheme = MacosTheme.of(context);
    final isDark = macTheme.brightness == Brightness.dark;

    // Use AppColors for consistent theming
    final backgroundColor = isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.6)
        : Colors.black.withValues(alpha: 0.15);
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340, minHeight: 280),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 1),
            boxShadow: [
              BoxShadow(
                color: shadowColor,
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                      width: 0.5,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/icon/window_icon.png',
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Cheddar Proxy',
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                _AboutContent(
                  showCloseButton: false,
                  showIcon: false,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  compact: true,
                ),
                const SizedBox(height: 16),
                Center(
                  child: PushButton(
                    controlSize: ControlSize.regular,
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AboutContent extends StatelessWidget {
  final bool showCloseButton;
  final bool showIcon;
  final double? width;
  final EdgeInsetsGeometry padding;
  final bool compact;

  const _AboutContent({
    required this.showCloseButton,
    required this.showIcon,
    this.width,
    required this.padding,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;
    final state = context.watch<TrafficState>();

    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    // Adjust sizes based on compact mode
    final titleSize = compact
        ? 0.0
        : 20.0; // Hide title in compact (shown elsewhere)
    final subtitleSize = compact ? 12.0 : 14.0;
    final infoSize = compact ? 13.0 : 13.0;
    final copyrightSize = compact ? 11.0 : 11.0;
    final vSpaceSmall = compact ? 4.0 : 6.0;
    final vSpaceMed = compact ? 10.0 : 16.0;

    final content = Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Container(
              width: compact ? 40 : 56,
              height: compact ? 40 : 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(compact ? 8 : 12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 0.8,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                'assets/icon/window_icon.png',
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
            ),
            SizedBox(height: compact ? 8 : 12),
          ],
          if (!compact) ...[
            Text(
              'Cheddar Proxy',
              style: TextStyle(
                color: textPrimary,
                fontSize: titleSize,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            'Free, open-source network traffic inspector',
            style: TextStyle(color: textSecondary, fontSize: subtitleSize),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: vSpaceMed),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return SizedBox(height: compact ? 14 : 20);
              }
              final info = snapshot.data!;
              return _InfoRow(
                label: 'App Version',
                value: '${info.version} (${info.buildNumber})',
                textPrimary: textPrimary,
                textMuted: textMuted,
                fontSize: infoSize,
              );
            },
          ),
          SizedBox(height: vSpaceSmall),
          _InfoRow(
            label: 'Rust Core',
            value: 'v${state.rustVersion}',
            textPrimary: textPrimary,
            textMuted: textMuted,
            fontSize: infoSize,
          ),
          SizedBox(height: vSpaceMed),
          Text(
            '© 2025 Cheddar Proxy. MIT License.',
            style: TextStyle(color: textMuted, fontSize: copyrightSize),
            textAlign: TextAlign.center,
          ),
          if (showCloseButton) ...[
            SizedBox(height: compact ? 8 : 12),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Close', style: TextStyle(color: AppColors.primary)),
            ),
          ],
        ],
      ),
    );

    if (width == null) {
      return content;
    }

    return SizedBox(width: width, child: content);
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color textPrimary;
  final Color textMuted;
  final double fontSize;

  const _InfoRow({
    required this.label,
    required this.value,
    required this.textPrimary,
    required this.textMuted,
    this.fontSize = 13,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(color: textMuted, fontSize: fontSize),
        ),
        Text(
          value,
          style: TextStyle(
            color: textPrimary,
            fontSize: fontSize,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
