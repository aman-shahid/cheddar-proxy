import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/update_service.dart';

/// Subtle update banner shown at the top of the app
class UpdateBanner extends StatelessWidget {
  final UpdateInfo update;
  final VoidCallback onDismiss;

  const UpdateBanner({
    super.key,
    required this.update,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: isDark ? 0.15 : 0.1),
        border: Border(
          bottom: BorderSide(
            color: AppColors.primary.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.system_update_outlined,
            color: AppColors.primary,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'A new version (${update.version}) is available',
              style: TextStyle(
                color: isDark
                    ? AppColors.textPrimary
                    : AppColorsLight.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          _BannerButton(
            label: 'Download',
            isPrimary: true,
            onPressed: () => _openDownload(update),
          ),
          const SizedBox(width: 8),
          _BannerButton(
            label: 'Dismiss',
            isPrimary: false,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }

  void _openDownload(UpdateInfo update) {
    final url = update.downloadUrl ?? update.releaseUrl;
    launchUrl(Uri.parse(url));
  }
}

class _BannerButton extends StatefulWidget {
  final String label;
  final bool isPrimary;
  final VoidCallback onPressed;

  const _BannerButton({
    required this.label,
    required this.isPrimary,
    required this.onPressed,
  });

  @override
  State<_BannerButton> createState() => _BannerButtonState();
}

class _BannerButtonState extends State<_BannerButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.isPrimary
                ? (_isHovered ? AppColors.primaryDark : AppColors.primary)
                : (_isHovered
                      ? (isDark
                            ? Colors.white.withValues(alpha: 0.1)
                            : Colors.black.withValues(alpha: 0.05))
                      : Colors.transparent),
            borderRadius: BorderRadius.circular(4),
            border: widget.isPrimary
                ? null
                : Border.all(
                    color: isDark
                        ? AppColors.textMuted.withValues(alpha: 0.3)
                        : AppColorsLight.textMuted.withValues(alpha: 0.3),
                  ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.isPrimary
                  ? Colors.white
                  : (isDark
                        ? AppColors.textSecondary
                        : AppColorsLight.textSecondary),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
