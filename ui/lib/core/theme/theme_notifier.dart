import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Theme mode options
enum AppThemeMode { system, light, dark, darkPlus }

/// Notifier for theme state management
class ThemeNotifier extends ChangeNotifier {
  AppThemeMode _mode = AppThemeMode.dark; // Default to dark
  Brightness _systemBrightness = Brightness.dark;

  AppThemeMode get mode => _mode;

  ThemeMode get themeMode {
    switch (_mode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
      case AppThemeMode.darkPlus:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  /// Current theme based on mode
  ThemeData get theme {
    switch (_mode) {
      case AppThemeMode.light:
        AppColors.useLightPalette();
        return AppTheme.lightTheme;
      case AppThemeMode.dark:
        AppColors.useDarkPalette();
        return AppTheme.darkTheme;
      case AppThemeMode.darkPlus:
        AppColors.useDarkPlusPalette();
        return AppTheme.darkPlusTheme;
      case AppThemeMode.system:
        AppColors.updateForBrightness(_effectiveBrightness);
        return _effectiveBrightness == Brightness.dark
            ? AppTheme.darkTheme
            : AppTheme.lightTheme;
    }
  }

  /// The effective brightness (resolved system mode)
  Brightness get _effectiveBrightness {
    switch (_mode) {
      case AppThemeMode.light:
        return Brightness.light;
      case AppThemeMode.dark:
      case AppThemeMode.darkPlus:
        return Brightness.dark;
      case AppThemeMode.system:
        return _systemBrightness;
    }
  }

  /// Whether currently using dark mode
  bool get isDarkMode => _effectiveBrightness == Brightness.dark;

  /// Set the theme mode
  void setMode(AppThemeMode mode) {
    _mode = mode;
    _applyPaletteForCurrentMode();
    notifyListeners();
  }

  /// Toggle between light and dark (ignores system)
  void toggleTheme() {
    if (_mode == AppThemeMode.dark) {
      setMode(AppThemeMode.light);
    } else {
      setMode(AppThemeMode.dark);
    }
  }

  /// Update system brightness (called when system changes)
  void updateSystemBrightness(Brightness brightness) {
    _systemBrightness = brightness;
    if (_mode == AppThemeMode.system) {
      _applyPaletteForCurrentMode();
      notifyListeners();
    }
  }

  void _applyPaletteForCurrentMode() {
    switch (_mode) {
      case AppThemeMode.light:
        AppColors.useLightPalette();
        break;
      case AppThemeMode.dark:
        AppColors.useDarkPalette();
        break;
      case AppThemeMode.darkPlus:
        AppColors.useDarkPlusPalette();
        break;
      case AppThemeMode.system:
        AppColors.updateForBrightness(_systemBrightness);
        break;
    }
  }

  /// Icon for current theme mode
  IconData get modeIcon {
    switch (_mode) {
      case AppThemeMode.light:
        return Icons.light_mode;
      case AppThemeMode.dark:
        return Icons.dark_mode;
      case AppThemeMode.darkPlus:
        return Icons.nightlight_round;
      case AppThemeMode.system:
        return Icons.brightness_auto;
    }
  }

  /// Label for current theme mode
  String get modeLabel {
    switch (_mode) {
      case AppThemeMode.light:
        return 'Light';
      case AppThemeMode.dark:
        return 'Dark';
      case AppThemeMode.darkPlus:
        return 'Dark+';
      case AppThemeMode.system:
        return 'System';
    }
  }
}
