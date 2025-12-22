import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Shared typography helpers for dialog/pop-up components.
class DialogStyles {
  DialogStyles._();

  static TextStyle title(bool isDark) => TextStyle(
    color: isDark ? AppColors.textPrimary : AppColorsLight.textPrimary,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  static TextStyle subtitle(bool isDark) => TextStyle(
    color: isDark ? AppColors.textSecondary : AppColorsLight.textSecondary,
    fontSize: 13,
  );

  static TextStyle sectionTitle(bool isDark) => TextStyle(
    color: isDark ? AppColors.textPrimary : AppColorsLight.textPrimary,
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );

  static TextStyle body(bool isDark) => TextStyle(
    color: isDark ? AppColors.textSecondary : AppColorsLight.textSecondary,
    fontSize: 13,
    height: 1.4,
  );

  static TextStyle tabLabel(bool isDark) => TextStyle(
    color: isDark ? AppColors.textPrimary : AppColorsLight.textPrimary,
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );

  static TextStyle tabLabelInactive(bool isDark) => TextStyle(
    color: isDark ? AppColors.textSecondary : AppColorsLight.textSecondary,
    fontSize: 13,
  );
}

class DialogButtonStyles {
  DialogButtonStyles._();

  static ButtonStyle primary(bool isDark) {
    final color = isDark ? AppColors.primaryLight : AppColors.primary;
    return TextButton.styleFrom(
      foregroundColor: color,
      textStyle: DialogStyles.body(
        isDark,
      ).copyWith(fontWeight: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
  }

  static ButtonStyle secondary(bool isDark) {
    final color = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    return TextButton.styleFrom(
      foregroundColor: color,
      disabledForegroundColor: color.withValues(alpha: 0.4),
      textStyle: DialogStyles.body(isDark),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    );
  }
}
