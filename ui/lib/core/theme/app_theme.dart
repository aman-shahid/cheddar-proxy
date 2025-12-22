import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Cheddar Proxy color palette - Dark mode
class AppColorsDark {
  AppColorsDark._();

  // Base colors
  static const Color background = Color(0xFF1E1E2E);
  static const Color surface = Color(0xFF2A2A3C);
  static const Color surfaceLight = Color(0xFF363649);
  static const Color surfaceBorder = Color(0xFF3D3D52);

  // Text colors
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  // Syntax colors
  static const Color headerKey = Color(
    0xFFE5A054,
  ); // Warm amber for header keys
}

/// Cheddar Proxy color palette - Dark+ (darker variant)
class AppColorsDarkPlus {
  AppColorsDarkPlus._();

  static const Color background = Color(0xFF0C0F16);
  static const Color surface = Color(0xFF151922);
  static const Color surfaceLight = Color(0xFF1F2532);
  static const Color surfaceBorder = Color(0xFF2A3243);

  static const Color textPrimary = Color(0xFFF5F7FA);
  static const Color textSecondary = Color(0xFFC6CEE0);
  static const Color textMuted = Color(0xFFA0A9BC);

  // Syntax colors
  static const Color headerKey = Color(
    0xFFD49A5A,
  ); // Warm amber for header keys
}

/// Cheddar Proxy color palette - Light mode
class AppColorsLight {
  AppColorsLight._();

  // Base colors
  static const Color background = Color(0xFFF8FAFC);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceLight = Color(0xFFF1F5F9);
  static const Color surfaceBorder = Color(0xFFE2E8F0);

  // Text colors
  static const Color textPrimary = Color(0xFF1E293B);
  static const Color textSecondary = Color(0xFF475569);
  static const Color textMuted = Color(0xFF94A3B8);

  // Syntax colors
  static const Color headerKey = Color(
    0xFFB5651D,
  ); // Darker amber for light mode
}

/// Shared colors (same in both modes)
class AppColors {
  AppColors._();

  // Primary accent
  static const Color primary = Colors.amber; // Cheddar Orange
  static const Color primaryLight = Color(0xFFFFCC80); // Lighter amber
  static const Color primaryDark = Color(0xFFD97706); // Darker amber

  // Status colors
  static const Color success = Color(0xFF22C55E);
  static const Color successDark = Color(0xFF15803D);
  static const Color redirect = Color(0xFFF59E0B);
  static const Color redirectDark = Color(0xFFD97706);
  static const Color clientError = Color(0xFFEF4444);
  static const Color serverError = Color(0xFFDC2626);

  // Method colors
  static const Color methodGet = Color(0xFF22C55E);
  static const Color methodPost = Color(0xFF3B82F6);
  static const Color methodPut = Color(0xFFF59E0B);
  static const Color methodPatch = Color(0xFFF97316);
  static const Color methodDelete = Color(0xFFEF4444);
  static const Color methodOptions = Color(0xFF8B5CF6);
  static const Color methodHead = Color(0xFF06B6D4);

  // These will be set based on current theme
  static Color background = AppColorsDark.background;
  static Color surface = AppColorsDark.surface;
  static Color surfaceLight = AppColorsDark.surfaceLight;
  static Color surfaceBorder = AppColorsDark.surfaceBorder;
  static Color textPrimary = AppColorsDark.textPrimary;
  static Color textSecondary = AppColorsDark.textSecondary;
  static Color textMuted = AppColorsDark.textMuted;

  /// Update colors based on brightness
  static void updateForBrightness(Brightness brightness) {
    if (brightness == Brightness.dark) {
      useDarkPalette();
    } else {
      useLightPalette();
    }
  }

  static void useDarkPalette() {
    background = AppColorsDark.background;
    surface = AppColorsDark.surface;
    surfaceLight = AppColorsDark.surfaceLight;
    surfaceBorder = AppColorsDark.surfaceBorder;
    textPrimary = AppColorsDark.textPrimary;
    textSecondary = AppColorsDark.textSecondary;
    textMuted = AppColorsDark.textMuted;
  }

  static void useDarkPlusPalette() {
    background = AppColorsDarkPlus.background;
    surface = AppColorsDarkPlus.surface;
    surfaceLight = AppColorsDarkPlus.surfaceLight;
    surfaceBorder = AppColorsDarkPlus.surfaceBorder;
    textPrimary = AppColorsDarkPlus.textPrimary;
    textSecondary = AppColorsDarkPlus.textSecondary;
    textMuted = AppColorsDarkPlus.textMuted;
  }

  static void useLightPalette() {
    background = AppColorsLight.background;
    surface = AppColorsLight.surface;
    surfaceLight = AppColorsLight.surfaceLight;
    surfaceBorder = AppColorsLight.surfaceBorder;
    textPrimary = AppColorsLight.textPrimary;
    textSecondary = AppColorsLight.textSecondary;
    textMuted = AppColorsLight.textMuted;
  }

  /// Get color for HTTP method
  static Color getMethodColor(String method) {
    switch (method.toUpperCase()) {
      case 'GET':
        return methodGet;
      case 'POST':
        return methodPost;
      case 'PUT':
        return methodPut;
      case 'PATCH':
        return methodPatch;
      case 'DELETE':
        return methodDelete;
      case 'OPTIONS':
        return methodOptions;
      case 'HEAD':
        return methodHead;
      default:
        return textSecondary;
    }
  }

  /// Get color for HTTP status code
  static Color getStatusColor(int statusCode) {
    if (statusCode >= 200 && statusCode < 300) {
      return success;
    } else if (statusCode >= 300 && statusCode < 400) {
      return redirect;
    } else if (statusCode >= 400 && statusCode < 500) {
      return clientError;
    } else if (statusCode >= 500) {
      return serverError;
    }
    return textSecondary;
  }
}

/// App theme configuration
class AppTheme {
  AppTheme._();

  static TextTheme _getNativeTextTheme(TextTheme base) {
    if (Platform.isMacOS) {
      return base.apply(fontFamily: '.AppleSystemUIFont');
    }
    if (Platform.isWindows) {
      return base.apply(fontFamily: 'Segoe UI Variable');
    }
    return GoogleFonts.interTextTheme(base);
  }

  static ThemeData get darkTheme {
    final baseTextTheme = _getNativeTextTheme(ThemeData.dark().textTheme);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColorsDark.background,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        secondary: AppColors.primaryLight,
        surface: AppColorsDark.surface,
        error: AppColors.clientError,
        onPrimary: AppColorsDark.textPrimary,
        onSecondary: AppColorsDark.textPrimary,
        onSurface: AppColorsDark.textPrimary,
        onError: AppColorsDark.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColorsDark.surface,
        foregroundColor: AppColorsDark.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: AppColorsDark.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColorsDark.surfaceBorder, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColorsDark.surfaceBorder,
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColorsDark.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColorsDark.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColorsDark.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        hintStyle: const TextStyle(color: AppColorsDark.textMuted),
      ),
      textTheme: baseTextTheme.copyWith(
        displayLarge: baseTextTheme.displayLarge?.copyWith(
          color: AppColorsDark.textPrimary,
          fontSize: 33,
          fontWeight: FontWeight.bold,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          color: AppColorsDark.textPrimary,
          fontSize: 25,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          color: AppColorsDark.textPrimary,
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          color: AppColorsDark.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(
          color: AppColorsDark.textPrimary,
          fontSize: 15,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(
          color: AppColorsDark.textSecondary,
          fontSize: 14,
        ),
        bodySmall: baseTextTheme.bodySmall?.copyWith(
          color: AppColorsDark.textMuted,
          fontSize: 13,
        ),
        labelSmall: baseTextTheme.labelSmall?.copyWith(
          color: AppColorsDark.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      iconTheme: const IconThemeData(
        color: AppColorsDark.textSecondary,
        size: 20,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColorsDark.surfaceLight,
          borderRadius: BorderRadius.circular(4),
        ),
        textStyle: const TextStyle(
          color: AppColorsDark.textPrimary,
          fontSize: 12,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColorsDark.surface,
        textStyle: GoogleFonts.inter(
          fontSize: 12,
          color: AppColorsDark.textPrimary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColorsDark.surface,
        contentTextStyle: const TextStyle(color: AppColorsDark.textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      scrollbarTheme: _getPlatformScrollbarTheme(
        thumbColor: AppColorsDark.textMuted,
        isDark: true,
      ),
    );
  }

  /// Get platform-specific scrollbar theme
  static ScrollbarThemeData _getPlatformScrollbarTheme({
    required Color thumbColor,
    required bool isDark,
  }) {
    // Windows 11 uses thinner, more subtle scrollbars
    if (Platform.isWindows) {
      return ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return thumbColor.withValues(alpha: 0.7);
          }
          if (states.contains(WidgetState.dragged)) {
            return thumbColor.withValues(alpha: 0.9);
          }
          return thumbColor.withValues(alpha: 0.4);
        }),
        thickness: WidgetStateProperty.resolveWith((states) {
          // Windows scrollbars expand on hover
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.dragged)) {
            return 8.0;
          }
          return 4.0;
        }),
        radius: const Radius.circular(2), // Less rounded for Windows
        crossAxisMargin: 1,
        mainAxisMargin: 1,
      );
    }

    // macOS/Linux - standard styling
    return ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) {
          return thumbColor.withValues(alpha: 0.6);
        }
        if (states.contains(WidgetState.dragged)) {
          return thumbColor.withValues(alpha: 0.8);
        }
        return thumbColor.withValues(alpha: 0.3);
      }),
      thickness: WidgetStateProperty.all(6),
      radius: const Radius.circular(3),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
    );
  }

  static ThemeData get darkPlusTheme {
    final baseTextTheme = _getNativeTextTheme(ThemeData.dark().textTheme);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColorsDarkPlus.background,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        secondary: AppColors.primaryLight,
        surface: AppColorsDarkPlus.surface,
        error: AppColors.clientError,
        onPrimary: AppColorsDarkPlus.textPrimary,
        onSecondary: AppColorsDarkPlus.textPrimary,
        onSurface: AppColorsDarkPlus.textPrimary,
        onError: AppColorsDarkPlus.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColorsDarkPlus.surface,
        foregroundColor: AppColorsDarkPlus.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: AppColorsDarkPlus.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(
            color: AppColorsDarkPlus.surfaceBorder,
            width: 1,
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColorsDarkPlus.surfaceBorder,
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColorsDarkPlus.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColorsDarkPlus.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColorsDarkPlus.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        hintStyle: const TextStyle(color: AppColorsDarkPlus.textMuted),
      ),
      textTheme: baseTextTheme.copyWith(
        displayLarge: baseTextTheme.displayLarge?.copyWith(
          color: AppColorsDarkPlus.textPrimary,
          fontSize: 33,
          fontWeight: FontWeight.bold,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          color: AppColorsDarkPlus.textPrimary,
          fontSize: 25,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          color: AppColorsDarkPlus.textPrimary,
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          color: AppColorsDarkPlus.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(
          color: AppColorsDarkPlus.textPrimary,
          fontSize: 15,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(
          color: AppColorsDarkPlus.textSecondary,
          fontSize: 14,
        ),
        bodySmall: baseTextTheme.bodySmall?.copyWith(
          color: AppColorsDarkPlus.textMuted,
          fontSize: 13,
        ),
        labelSmall: baseTextTheme.labelSmall?.copyWith(
          color: AppColorsDarkPlus.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      iconTheme: const IconThemeData(color: AppColorsDarkPlus.textSecondary),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColorsDarkPlus.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColorsDarkPlus.surface,
        textStyle: GoogleFonts.inter(
          fontSize: 12,
          color: AppColorsDarkPlus.textPrimary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColorsDarkPlus.surface,
        contentTextStyle: const TextStyle(color: AppColorsDarkPlus.textPrimary),
        actionTextColor: AppColors.primaryLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: AppColorsDarkPlus.surfaceBorder),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static ThemeData get lightTheme {
    final baseTextTheme = _getNativeTextTheme(ThemeData.light().textTheme);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColorsLight.background,
      colorScheme: const ColorScheme.light(
        primary: AppColors.primary,
        secondary: AppColors.primaryLight,
        surface: AppColorsLight.surface,
        error: AppColors.clientError,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: AppColorsLight.textPrimary,
        onError: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColorsLight.surface,
        foregroundColor: AppColorsLight.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: AppColorsLight.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColorsLight.surfaceBorder, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColorsLight.surfaceBorder,
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColorsLight.surfaceLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColorsLight.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColorsLight.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        hintStyle: const TextStyle(color: AppColorsLight.textMuted),
      ),
      textTheme: baseTextTheme.copyWith(
        displayLarge: baseTextTheme.displayLarge?.copyWith(
          color: AppColorsLight.textPrimary,
          fontSize: 33,
          fontWeight: FontWeight.bold,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          color: AppColorsLight.textPrimary,
          fontSize: 25,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          color: AppColorsLight.textPrimary,
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          color: AppColorsLight.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(
          color: AppColorsLight.textPrimary,
          fontSize: 15,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(
          color: AppColorsLight.textSecondary,
          fontSize: 14,
        ),
        bodySmall: baseTextTheme.bodySmall?.copyWith(
          color: AppColorsLight.textMuted,
          fontSize: 13,
        ),
        labelSmall: baseTextTheme.labelSmall?.copyWith(
          color: AppColorsLight.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      iconTheme: const IconThemeData(
        color: AppColorsLight.textSecondary,
        size: 20,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColorsLight.textPrimary,
          borderRadius: BorderRadius.circular(4),
        ),
        textStyle: const TextStyle(color: AppColorsLight.surface, fontSize: 12),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColorsLight.surface,
        textStyle: GoogleFonts.inter(
          fontSize: 12,
          color: AppColorsLight.textPrimary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColorsLight.textPrimary,
        contentTextStyle: const TextStyle(color: AppColorsLight.surface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      scrollbarTheme: _getPlatformScrollbarTheme(
        thumbColor: AppColorsLight.textMuted,
        isDark: false,
      ),
    );
  }
}
