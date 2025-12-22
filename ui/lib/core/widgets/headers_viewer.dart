import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A widget that displays HTTP headers in a formatted key-value list.
/// Used by both request detail panel and composer.
class HeadersViewer extends StatelessWidget {
  final Map<String, String> headers;
  final bool isDark;

  /// If true, uses a more compact style
  final bool compact;

  const HeadersViewer({
    super.key,
    required this.headers,
    required this.isDark,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (headers.isEmpty) {
      final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          'No headers',
          style: TextStyle(color: textMuted, fontSize: 11),
        ),
      );
    }

    final background = isDark
        ? AppColors.background
        : AppColorsLight.surfaceLight;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final keyColor = isDark
        ? AppColorsDark.headerKey
        : AppColorsLight.headerKey;

    final padding = compact ? 6.0 : 8.0;
    final keyWidth = compact ? 120.0 : 150.0;

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(compact ? 4 : 8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: headers.entries.map((entry) {
          return Container(
            padding: EdgeInsets.symmetric(
              horizontal: padding + 2,
              vertical: padding,
            ),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: borderColor.withValues(alpha: 0.5)),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: keyWidth,
                  child: SelectableText(
                    entry.key,
                    style: TextStyle(
                      color: keyColor,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    entry.value,
                    style: TextStyle(
                      color: textSecondary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// A section header widget matching the request detail panel style.
class SectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final String? subtitle;
  final bool isDark;

  const SectionHeader({
    super.key,
    required this.title,
    this.count,
    this.subtitle,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;
    final surfaceLight = isDark
        ? AppColors.surfaceLight
        : AppColorsLight.surfaceLight;

    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            color: textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(color: textSecondary, fontSize: 11),
            ),
          ),
        ],
        if (subtitle != null) ...[
          const SizedBox(width: 8),
          Text(subtitle!, style: TextStyle(color: textMuted, fontSize: 11)),
        ],
      ],
    );
  }
}
