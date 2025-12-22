import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/theme_notifier.dart';
import 'package:provider/provider.dart';

import 'macos_button.dart';

class _ConfirmIntent extends Intent {
  const _ConfirmIntent();
}

class _CancelIntent extends Intent {
  const _CancelIntent();
}

/// Shows a platform-native confirmation dialog for destructive actions.
/// Returns true if confirmed, false if cancelled.
Future<bool> showDeleteConfirmation({
  required BuildContext context,
  required String message,
  String title = 'Delete Request',
  String confirmLabel = 'Delete',
  String cancelLabel = 'Cancel',
}) async {
  return showConfirmation(
    context: context,
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    isDestructive: true,
  );
}

/// Shows a platform-native confirmation dialog.
/// Returns true if confirmed, false if cancelled.
/// Set [isDestructive] to true for delete/clear actions (red button).
Future<bool> showConfirmation({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool isDestructive = false,
}) async {
  final themeNotifier = context.read<ThemeNotifier>();
  final isDark = themeNotifier.isDarkMode;

  if (Platform.isMacOS) {
    return await _showMacOSConfirmation(
      context: context,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      isDark: isDark,
      isDestructive: isDestructive,
    );
  } else if (Platform.isWindows) {
    return await _showWindowsConfirmation(
      context: context,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      isDark: isDark,
      isDestructive: isDestructive,
    );
  } else {
    return await _showMaterialConfirmation(
      context: context,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      isDark: isDark,
      isDestructive: isDestructive,
    );
  }
}

Future<bool> _showMacOSConfirmation({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
  required bool isDark,
  bool isDestructive = false,
}) async {
  final macTheme = MacosThemeData(
    brightness: isDark ? Brightness.dark : Brightness.light,
  );

  final textColor = isDark ? AppColors.textPrimary : AppColorsLight.textPrimary;
  final textSecondary = isDark
      ? AppColors.textSecondary
      : AppColorsLight.textSecondary;
  final surface = isDark ? AppColors.surface : AppColorsLight.surface;
  final borderColor = isDark
      ? AppColors.surfaceBorder
      : AppColorsLight.surfaceBorder;

  final result = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (context) => Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.enter): const _ConfirmIntent(),
        LogicalKeySet(LogicalKeyboardKey.numpadEnter): const _ConfirmIntent(),
        LogicalKeySet(LogicalKeyboardKey.space): const _ConfirmIntent(),
        LogicalKeySet(LogicalKeyboardKey.escape): const _CancelIntent(),
      },
      child: Actions(
        actions: {
          _ConfirmIntent: CallbackAction<_ConfirmIntent>(
            onInvoke: (_) => Navigator.of(context).pop(true),
          ),
          _CancelIntent: CallbackAction<_CancelIntent>(
            onInvoke: (_) => Navigator.of(context).pop(false),
          ),
        },
        child: FocusScope(
          autofocus: true,
          child: MacosTheme(
            data: macTheme,
            child: Center(
              child: Container(
                width: 280,
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Warning icon (smaller)
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 36,
                          color: Colors.orange.shade600,
                        ),
                        const SizedBox(height: 10),
                        // Title
                        Text(
                          title,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        // Message
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: textSecondary, fontSize: 11),
                        ),
                        const SizedBox(height: 14),
                        // Buttons - compact macOS style
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            MacOSButton(
                              label: cancelLabel,
                              onPressed: () => Navigator.of(context).pop(false),
                              isPrimary: false,
                              isDark: isDark,
                            ),
                            const SizedBox(width: 8),
                            MacOSButton(
                              label: confirmLabel,
                              onPressed: () => Navigator.of(context).pop(true),
                              isPrimary: true,
                              isDestructive: isDestructive,
                              isDark: isDark,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  return result ?? false;
}

Future<bool> _showWindowsConfirmation({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
  required bool isDark,
  bool isDestructive = false,
}) async {
  final fluentTheme = isDark
      ? fluent.FluentThemeData.dark()
      : fluent.FluentThemeData.light();

  final buttonColor = isDestructive ? Colors.red.shade600 : AppColors.primary;

  final result = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (context) => Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.enter): const _ConfirmIntent(),
        LogicalKeySet(LogicalKeyboardKey.numpadEnter): const _ConfirmIntent(),
        LogicalKeySet(LogicalKeyboardKey.space): const _ConfirmIntent(),
        LogicalKeySet(LogicalKeyboardKey.escape): const _CancelIntent(),
      },
      child: Actions(
        actions: {
          _ConfirmIntent: CallbackAction<_ConfirmIntent>(
            onInvoke: (_) => Navigator.of(context).pop(true),
          ),
          _CancelIntent: CallbackAction<_CancelIntent>(
            onInvoke: (_) => Navigator.of(context).pop(false),
          ),
        },
        child: FocusScope(
          autofocus: true,
          child: fluent.FluentTheme(
            data: fluentTheme,
            child: fluent.ContentDialog(
              title: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 24,
                    color: Colors.orange.shade600,
                  ),
                  const SizedBox(width: 12),
                  Text(title),
                ],
              ),
              content: Text(message),
              actions: [
                fluent.Button(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(cancelLabel),
                ),
                fluent.FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: fluent.ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      final color = buttonColor;
                      if (states.isPressed) {
                        return color.withValues(alpha: 0.8);
                      }
                      if (states.isHovered) {
                        return color.withValues(alpha: 0.9);
                      }
                      return color;
                    }),
                  ),
                  child: Text(confirmLabel),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  return result ?? false;
}

Future<bool> _showMaterialConfirmation({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
  required bool isDark,
  bool isDestructive = false,
}) async {
  final buttonColor = isDestructive ? Colors.red : AppColors.primary;

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.enter): const _ConfirmIntent(),
        LogicalKeySet(LogicalKeyboardKey.numpadEnter): const _ConfirmIntent(),
        LogicalKeySet(LogicalKeyboardKey.space): const _ConfirmIntent(),
        LogicalKeySet(LogicalKeyboardKey.escape): const _CancelIntent(),
      },
      child: Actions(
        actions: {
          _ConfirmIntent: CallbackAction<_ConfirmIntent>(
            onInvoke: (_) => Navigator.of(context).pop(true),
          ),
          _CancelIntent: CallbackAction<_CancelIntent>(
            onInvoke: (_) => Navigator.of(context).pop(false),
          ),
        },
        child: FocusScope(
          autofocus: true,
          child: AlertDialog(
            icon: Icon(
              Icons.warning_amber_rounded,
              size: 48,
              color: Colors.orange.shade600,
            ),
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(cancelLabel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(foregroundColor: buttonColor),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  return result ?? false;
}
