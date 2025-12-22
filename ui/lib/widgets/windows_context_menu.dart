import 'dart:async';

import 'package:flutter/material.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_notifier.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

/// Entry types for Windows context menus
abstract class WindowsContextMenuEntry<T> {
  const WindowsContextMenuEntry();
}

/// Divider entry
class WindowsContextMenuDivider<T> extends WindowsContextMenuEntry<T> {
  const WindowsContextMenuDivider();
}

/// Label entry (non-selectable)
class WindowsContextMenuLabel<T> extends WindowsContextMenuEntry<T> {
  const WindowsContextMenuLabel({required this.label, this.icon, this.color});
  final String label;
  final IconData? icon;
  final Color? color;
}

/// Selectable menu item
class WindowsContextMenuItem<T> extends WindowsContextMenuEntry<T> {
  const WindowsContextMenuItem({
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

/// Shows a Windows-style context menu using Fluent UI styling.
Future<T?> showWindowsContextMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<WindowsContextMenuEntry<T>> entries,
  double minWidth = 120,
  Color? backgroundColor,
  Color? borderColor,
  Color? highlightColor,
  Color? textColor,
  Color? shortcutColor,
}) async {
  final themeNotifier = context.read<ThemeNotifier>();
  final isDark = themeNotifier.isDarkMode;

  final surface =
      backgroundColor ?? (isDark ? AppColors.surface : AppColorsLight.surface);
  final border =
      borderColor ??
      (isDark ? AppColors.surfaceBorder : AppColorsLight.surfaceBorder);
  final effectiveTextColor =
      textColor ??
      (isDark ? AppColors.textPrimary : AppColorsLight.textPrimary);
  final effectiveShortcutColor =
      shortcutColor ??
      (isDark ? AppColors.textSecondary : AppColorsLight.textSecondary);
  final hover =
      highlightColor ??
      (isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.06));

  final navigator = Navigator.of(context, rootNavigator: true);
  bool hasRequestedClose = false;

  void requestClose() {
    if (hasRequestedClose) return;
    hasRequestedClose = true;
    if (navigator.mounted) {
      unawaited(navigator.maybePop());
    }
  }

  final listener = _MenuWindowListener(onBlur: requestClose);
  windowManager.addListener(listener);

  Timer? focusMonitor;
  var isCheckingFocus = false;

  void startFocusMonitor() {
    focusMonitor = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (hasRequestedClose || isCheckingFocus) return;
      isCheckingFocus = true;
      windowManager
          .isFocused()
          .then((isFocused) {
            isCheckingFocus = false;
            if (!isFocused) {
              requestClose();
            }
          })
          .catchError((_) {
            isCheckingFocus = false;
          });
    });
  }

  startFocusMonitor();

  try {
    return await showDialog<T>(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: true,
      builder: (dialogContext) {
        return LayoutBuilder(
          builder: (context, constraints) {
            // Estimate menu width (will be refined by actual widget)
            const estimatedMenuWidth = 220.0;
            const estimatedMenuHeight = 300.0;

            // Adjust position to keep menu within bounds
            double left = position.dx;
            double top = position.dy;

            // If menu would overflow right edge, align to right edge
            if (left + estimatedMenuWidth > constraints.maxWidth) {
              left = constraints.maxWidth - estimatedMenuWidth - 8;
            }
            // Keep minimum left margin
            if (left < 8) left = 8;

            // If menu would overflow bottom, show above anchor
            if (top + estimatedMenuHeight > constraints.maxHeight) {
              top = constraints.maxHeight - estimatedMenuHeight - 8;
            }
            if (top < 8) top = 8;

            return Stack(
              children: [
                // Dismiss on tap outside
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => Navigator.of(dialogContext).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(color: Colors.transparent),
                  ),
                ),
                // Menu positioned with bounds checking
                Positioned(
                  left: left,
                  top: top,
                  child: Material(
                    color: Colors.transparent,
                    child: _WindowsContextMenuOverlay<T>(
                      entries: entries,
                      isDark: isDark,
                      surface: surface,
                      borderColor: border,
                      textColor: effectiveTextColor,
                      textSecondaryColor: effectiveShortcutColor,
                      hoverColor: hover,
                      minWidth: minWidth,
                      onSelected: (value) {
                        Navigator.of(dialogContext).pop(value);
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    focusMonitor?.cancel();
    focusMonitor = null;
    windowManager.removeListener(listener);
  }
}

/// Shows a Windows-style flyout panel (for filter dropdowns, etc.)
Future<void> showWindowsMenuPanel({
  required BuildContext context,
  required Offset position,
  required Widget child,
  Color? backgroundColor,
  Color? borderColor,
}) async {
  final themeNotifier = context.read<ThemeNotifier>();
  final isDark = themeNotifier.isDarkMode;

  final surface =
      backgroundColor ?? (isDark ? AppColors.surface : AppColorsLight.surface);
  final border =
      borderColor ??
      (isDark ? AppColors.surfaceBorder : AppColorsLight.surfaceBorder);

  final navigator = Navigator.of(context, rootNavigator: true);
  bool hasRequestedClose = false;

  void requestClose() {
    if (hasRequestedClose) return;
    hasRequestedClose = true;
    if (navigator.mounted) {
      unawaited(navigator.maybePop());
    }
  }

  final listener = _MenuWindowListener(onBlur: requestClose);
  windowManager.addListener(listener);

  Timer? focusMonitor;
  var isCheckingFocus = false;

  void startFocusMonitor() {
    focusMonitor = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (hasRequestedClose || isCheckingFocus) return;
      isCheckingFocus = true;
      windowManager
          .isFocused()
          .then((isFocused) {
            isCheckingFocus = false;
            if (!isFocused) {
              requestClose();
            }
          })
          .catchError((_) {
            isCheckingFocus = false;
          });
    });
  }

  startFocusMonitor();

  try {
    await showDialog(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: true,
      builder: (dialogContext) {
        return LayoutBuilder(
          builder: (context, constraints) {
            // Estimate panel dimensions
            const estimatedPanelWidth = 260.0;
            const estimatedPanelHeight = 350.0;

            // Adjust position to keep panel within bounds
            double left = position.dx;
            double top = position.dy;

            // If panel would overflow right edge, align to right edge
            if (left + estimatedPanelWidth > constraints.maxWidth) {
              left = constraints.maxWidth - estimatedPanelWidth - 8;
            }
            // Keep minimum left margin
            if (left < 8) left = 8;

            // If panel would overflow bottom, show above anchor
            if (top + estimatedPanelHeight > constraints.maxHeight) {
              top = constraints.maxHeight - estimatedPanelHeight - 8;
            }
            if (top < 8) top = 8;

            return Stack(
              children: [
                // Dismiss on tap outside
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => Navigator.of(dialogContext).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(color: Colors.transparent),
                  ),
                ),
                // Panel positioned with bounds checking
                Positioned(
                  left: left,
                  top: top,
                  child: Material(
                    color: Colors.transparent,
                    child: _WindowsPanelOverlay(
                      backgroundColor: surface,
                      borderColor: border,
                      child: child,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    focusMonitor?.cancel();
    focusMonitor = null;
    windowManager.removeListener(listener);
  }
}

class _WindowsPanelOverlay extends StatelessWidget {
  const _WindowsPanelOverlay({
    required this.child,
    required this.backgroundColor,
    required this.borderColor,
  });

  final Widget child;
  final Color backgroundColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
    );
  }
}

class _WindowsContextMenuOverlay<T> extends StatefulWidget {
  const _WindowsContextMenuOverlay({
    required this.entries,
    required this.isDark,
    required this.surface,
    required this.borderColor,
    required this.textColor,
    required this.textSecondaryColor,
    required this.hoverColor,
    required this.onSelected,
    this.minWidth = 120,
  });

  final List<WindowsContextMenuEntry<T>> entries;
  final bool isDark;
  final Color surface;
  final Color borderColor;
  final Color textColor;
  final Color textSecondaryColor;
  final Color hoverColor;
  final ValueChanged<T?> onSelected;
  final double minWidth;

  @override
  State<_WindowsContextMenuOverlay<T>> createState() =>
      _WindowsContextMenuOverlayState<T>();
}

class _WindowsContextMenuOverlayState<T>
    extends State<_WindowsContextMenuOverlay<T>> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    final textPrimary = widget.textColor;
    final textSecondary = widget.textSecondaryColor;
    final hoverColor = widget.hoverColor;

    return Container(
      constraints: BoxConstraints(
        minWidth: widget.minWidth,
        maxWidth: widget.minWidth + 80,
      ),
      decoration: BoxDecoration(
        color: widget.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: widget.borderColor, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < widget.entries.length; i++)
                _buildEntry(
                  widget.entries[i],
                  i,
                  textPrimary,
                  textSecondary,
                  hoverColor,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntry(
    WindowsContextMenuEntry<T> entry,
    int index,
    Color textPrimary,
    Color textSecondary,
    Color hoverColor,
  ) {
    if (entry is WindowsContextMenuDivider<T>) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: Divider(height: 1, color: widget.borderColor),
      );
    }

    if (entry is WindowsContextMenuLabel<T>) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            if (entry.icon != null) ...[
              Icon(entry.icon, size: 14, color: entry.color ?? textSecondary),
              const SizedBox(width: 8),
            ],
            Text(
              entry.label,
              style: TextStyle(
                color: entry.color ?? textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    final item = entry as WindowsContextMenuItem<T>;
    final isHovered = _hoveredIndex == index;

    // For selected items, use primary color like macOS does
    Color effectiveColor;
    if (item.isSelected) {
      effectiveColor = AppColors.primary;
    } else if (item.isDestructive) {
      effectiveColor = Colors.red;
    } else {
      effectiveColor = item.color ?? textPrimary;
    }

    final effectiveOpacity = item.enabled ? 1.0 : 0.4;
    final iconColor = item.isSelected
        ? AppColors.primary
        : (item.color ?? textSecondary);

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = null),
      child: GestureDetector(
        onTap: item.enabled ? () => widget.onSelected(item.value) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isHovered && item.enabled ? hoverColor : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: Opacity(
            opacity: effectiveOpacity,
            child: Row(
              children: [
                if (item.icon != null) ...[
                  Icon(item.icon, size: 14, color: iconColor),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      color: effectiveColor,
                      fontSize: 12,
                      fontWeight: item.isSelected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
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

class _MenuWindowListener extends WindowListener {
  _MenuWindowListener({required this.onBlur});

  final VoidCallback onBlur;

  @override
  void onWindowBlur() {
    onBlur();
  }
}
