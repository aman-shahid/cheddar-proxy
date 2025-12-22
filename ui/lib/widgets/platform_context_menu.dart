import 'dart:io';
import 'package:flutter/material.dart';
import 'macos_context_menu.dart';
import 'windows_context_menu.dart';

/// Platform-agnostic context menu entry
abstract class PlatformContextMenuEntry<T> {
  const PlatformContextMenuEntry();
}

/// Divider entry
class PlatformContextMenuDivider<T> extends PlatformContextMenuEntry<T> {
  const PlatformContextMenuDivider();
}

/// Label entry (non-selectable header)
class PlatformContextMenuLabel<T> extends PlatformContextMenuEntry<T> {
  const PlatformContextMenuLabel({required this.label, this.icon, this.color});
  final String label;
  final IconData? icon;
  final Color? color;
}

/// Selectable menu item
class PlatformContextMenuItem<T> extends PlatformContextMenuEntry<T> {
  const PlatformContextMenuItem({
    required this.label,
    this.value,
    this.icon,
    this.color,
    this.isSelected = false,
    this.isDestructive = false,
    this.enabled = true,
  });

  final String label;
  final T? value;
  final IconData? icon;
  final Color? color;
  final bool isSelected;
  final bool isDestructive;
  final bool enabled;
}

/// Shows a platform-appropriate context menu.
///
/// On macOS, uses native-styled macOS menu.
/// On Windows, uses Fluent UI styled menu.
/// On other platforms, falls back to Material-styled menu.
///
/// [minWidth] is only used on Windows to control menu width (default: 120).
Future<T?> showPlatformContextMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<PlatformContextMenuEntry<T>> entries,
  double minWidth = 120,
  double? macMenuWidth,
  Color? backgroundColor,
  Color? borderColor,
  Color? highlightColor,
  Color? textColor,
  Color? shortcutColor,
}) {
  if (Platform.isMacOS) {
    return showMacosContextMenu<T>(
      context: context,
      position: position,
      entries: _toMacosEntries(entries),
      menuWidth: macMenuWidth,
      backgroundColor: backgroundColor,
      borderColor: borderColor,
      highlightColor: highlightColor,
      textColor: textColor,
      shortcutColor: shortcutColor,
    );
  } else if (Platform.isWindows) {
    return showWindowsContextMenu<T>(
      context: context,
      position: position,
      entries: _toWindowsEntries(entries),
      minWidth: minWidth,
      backgroundColor: backgroundColor,
      borderColor: borderColor,
      highlightColor: highlightColor,
      textColor: textColor,
      shortcutColor: shortcutColor,
    );
  } else {
    // Fallback to macOS style for Linux (it looks fine)
    return showMacosContextMenu<T>(
      context: context,
      position: position,
      entries: _toMacosEntries(entries),
      backgroundColor: backgroundColor,
      borderColor: borderColor,
      highlightColor: highlightColor,
      textColor: textColor,
      shortcutColor: shortcutColor,
    );
  }
}

/// Shows a platform-appropriate menu panel (for dropdowns with custom content).
Future<void> showPlatformMenuPanel({
  required BuildContext context,
  required Offset position,
  required Widget child,
  Color? backgroundColor,
  Color? borderColor,
}) {
  if (Platform.isMacOS) {
    return showMacosMenuPanel(
      context: context,
      position: position,
      child: child,
      backgroundColor: backgroundColor,
      borderColor: borderColor,
    );
  } else if (Platform.isWindows) {
    return showWindowsMenuPanel(
      context: context,
      position: position,
      child: child,
      backgroundColor: backgroundColor,
      borderColor: borderColor,
    );
  } else {
    // Fallback to macOS style for Linux
    return showMacosMenuPanel(
      context: context,
      position: position,
      child: child,
      backgroundColor: backgroundColor,
      borderColor: borderColor,
    );
  }
}

/// Convert platform entries to macOS entries
List<MacosContextMenuEntry<T>> _toMacosEntries<T>(
  List<PlatformContextMenuEntry<T>> entries,
) {
  return entries.map((e) {
    if (e is PlatformContextMenuDivider<T>) {
      return MacosContextMenuDivider<T>();
    } else if (e is PlatformContextMenuLabel<T>) {
      return MacosContextMenuLabel<T>(
        label: e.label,
        icon: e.icon,
        color: e.color,
      );
    } else if (e is PlatformContextMenuItem<T>) {
      // MacosContextMenuItem requires non-null value, so we cast
      return MacosContextMenuItem<T>(
        label: e.label,
        value: e.value as T,
        icon: e.icon,
        selected: e.isSelected,
        destructive: e.isDestructive,
        enabled: e.enabled,
      );
    }
    throw ArgumentError('Unknown entry type: ${e.runtimeType}');
  }).toList();
}

/// Convert platform entries to Windows entries
List<WindowsContextMenuEntry<T>> _toWindowsEntries<T>(
  List<PlatformContextMenuEntry<T>> entries,
) {
  return entries.map((e) {
    if (e is PlatformContextMenuDivider<T>) {
      return WindowsContextMenuDivider<T>();
    } else if (e is PlatformContextMenuLabel<T>) {
      return WindowsContextMenuLabel<T>(
        label: e.label,
        icon: e.icon,
        color: e.color,
      );
    } else if (e is PlatformContextMenuItem<T>) {
      return WindowsContextMenuItem<T>(
        label: e.label,
        value: e.value,
        icon: e.icon,
        color: e.color,
        isSelected: e.isSelected,
        isDestructive: e.isDestructive,
        enabled: e.enabled,
      );
    }
    throw ArgumentError('Unknown entry type: ${e.runtimeType}');
  }).toList();
}
