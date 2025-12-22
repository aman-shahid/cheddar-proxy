import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:window_manager/window_manager.dart';

/// Base class for macOS-styled context menu entries.
abstract class MacosContextMenuEntry<T> {
  const MacosContextMenuEntry();
}

/// Divider entry for macOS-styled context menus.
class MacosContextMenuDivider<T> extends MacosContextMenuEntry<T> {
  const MacosContextMenuDivider();
}

/// Label-only entry for section headers or status rows.
class MacosContextMenuLabel<T> extends MacosContextMenuEntry<T> {
  const MacosContextMenuLabel({required this.label, this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;
}

/// Menu item entry backed by macOS visual styling.
class MacosContextMenuItem<T> extends MacosContextMenuEntry<T> {
  const MacosContextMenuItem({
    required this.value,
    required this.label,
    this.shortcut,
    this.icon,
    this.destructive = false,
    this.enabled = true,
    this.selected = false,
    this.activeColor,
  });

  final T value;
  final String label;
  final String? shortcut;
  final IconData? icon;
  final bool destructive;
  final bool enabled;
  final bool selected;
  final Color? activeColor;
}

/// Shows a macOS-style context menu using the macos_ui theming primitives.
Future<T?> showMacosContextMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<MacosContextMenuEntry<T>> entries,
  Color? backgroundColor,
  Color? borderColor,
  Color? highlightColor,
  Color? textColor,
  Color? shortcutColor,
  double? menuWidth,
}) {
  final overlay = Overlay.of(context);
  if (entries.isEmpty) {
    return Future<T?>.value(null);
  }

  final renderBox = overlay.context.findRenderObject();
  if (renderBox is! RenderBox) {
    return Future<T?>.value(null);
  }

  final localOffset = renderBox.globalToLocal(position);
  final overlaySize = renderBox.size;
  final brightness = Theme.of(context).brightness;

  final macosTheme = MacosThemeData(
    brightness: brightness,
    accentColor: AccentColor.purple,
    isMainWindow: true,
  );

  final completer = Completer<T?>();
  late OverlayEntry entry;

  late final _MenuWindowListener windowListener;
  Timer? focusMonitor;
  var isCheckingFocus = false;

  void close([T? value]) {
    if (!completer.isCompleted) {
      completer.complete(value);
    }
    focusMonitor?.cancel();
    focusMonitor = null;
    windowManager.removeListener(windowListener);
    entry.remove();
  }

  void startFocusMonitor() {
    focusMonitor = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (completer.isCompleted || isCheckingFocus) return;
      isCheckingFocus = true;
      windowManager
          .isFocused()
          .then((isFocused) {
            isCheckingFocus = false;
            if (!isFocused) {
              close(null);
            }
          })
          .catchError((_) {
            isCheckingFocus = false;
          });
    });
  }

  windowListener = _MenuWindowListener(onBlur: () => close(null));

  entry = OverlayEntry(
    builder: (overlayContext) => MacosTheme(
      data: macosTheme,
      child: _MacosContextMenuOverlay<T>(
        position: localOffset,
        overlaySize: overlaySize,
        entries: entries,
        onSelected: (value) => close(value),
        onDismissed: () => close(null),
        backgroundColor: backgroundColor,
        borderColor: borderColor,
        highlightColor: highlightColor,
        textColor: textColor,
        shortcutColor: shortcutColor,
        menuWidth: menuWidth,
      ),
    ),
  );

  overlay.insert(entry);
  windowManager.addListener(windowListener);
  startFocusMonitor();
  return completer.future;
}

Future<void> showMacosMenuPanel({
  required BuildContext context,
  required Offset position,
  required Widget child,
  double minWidth = 220,
  Color? backgroundColor,
  Color? borderColor,
}) {
  final overlay = Overlay.of(context);

  final renderBox = overlay.context.findRenderObject();
  if (renderBox is! RenderBox) return Future.value();

  final localOffset = renderBox.globalToLocal(position);
  final overlaySize = renderBox.size;
  final brightness = Theme.of(context).brightness;

  final macosTheme = MacosThemeData(brightness: brightness, isMainWindow: true);

  final completer = Completer<void>();
  late OverlayEntry entry;
  late final _MenuWindowListener windowListener;
  Timer? focusMonitor;
  var isCheckingFocus = false;

  void close() {
    if (!completer.isCompleted) {
      completer.complete();
    }
    focusMonitor?.cancel();
    focusMonitor = null;
    windowManager.removeListener(windowListener);
    entry.remove();
  }

  void startFocusMonitor() {
    focusMonitor = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (completer.isCompleted || isCheckingFocus) return;
      isCheckingFocus = true;
      windowManager
          .isFocused()
          .then((isFocused) {
            isCheckingFocus = false;
            if (!isFocused) {
              close();
            }
          })
          .catchError((_) {
            isCheckingFocus = false;
          });
    });
  }

  windowListener = _MenuWindowListener(onBlur: close);

  entry = OverlayEntry(
    builder: (overlayContext) => MacosTheme(
      data: macosTheme,
      child: _MacosPanelOverlay(
        position: localOffset,
        overlaySize: overlaySize,
        minWidth: minWidth,
        backgroundColor: backgroundColor,
        borderColor: borderColor,
        onDismissed: close,
        child: child,
      ),
    ),
  );

  overlay.insert(entry);
  windowManager.addListener(windowListener);
  startFocusMonitor();
  return completer.future;
}

class _MenuWindowListener extends WindowListener {
  _MenuWindowListener({required this.onBlur});

  final VoidCallback onBlur;

  @override
  void onWindowBlur() {
    onBlur();
  }
}

class _MacosPanelOverlay extends StatelessWidget {
  const _MacosPanelOverlay({
    required this.position,
    required this.overlaySize,
    required this.child,
    required this.onDismissed,
    required this.minWidth,
    this.backgroundColor,
    this.borderColor,
  });

  final Offset position;
  final Size overlaySize;
  final Widget child;
  final VoidCallback onDismissed;
  final double minWidth;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final macTheme = MacosTheme.of(context);
    final bgColor =
        backgroundColor ??
        (macTheme.brightness == Brightness.dark
            ? const Color(0xFF2B2B2F)
            : const Color(0xFFF2F2F7));
    final brColor =
        borderColor ??
        macTheme.dividerColor.withValues(
          alpha: macTheme.brightness == Brightness.dark ? 0.6 : 0.4,
        );

    final width = math
        .max(math.min(math.max(minWidth, 220), 320), 220)
        .toDouble();
    final maxHeight = math.min(overlaySize.height - 24, 420.0);

    double left = position.dx;
    double top = position.dy;

    left = left.clamp(12, math.max(12, overlaySize.width - width - 12));
    top = top.clamp(12, math.max(12, overlaySize.height - maxHeight - 12));

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismissed,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: RepaintBoundary(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: brColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: macTheme.brightness == Brightness.dark
                          ? 0.65
                          : 0.25,
                    ),
                    blurRadius: 18,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: minWidth,
                  maxWidth: width,
                  maxHeight: maxHeight,
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MacosContextMenuOverlay<T> extends StatefulWidget {
  const _MacosContextMenuOverlay({
    required this.position,
    required this.overlaySize,
    required this.entries,
    required this.onSelected,
    required this.onDismissed,
    this.backgroundColor,
    this.borderColor,
    this.highlightColor,
    this.textColor,
    this.shortcutColor,
    this.menuWidth,
  });

  final Offset position;
  final Size overlaySize;
  final List<MacosContextMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final VoidCallback onDismissed;
  final Color? backgroundColor;
  final Color? borderColor;
  final Color? highlightColor;
  final Color? textColor;
  final Color? shortcutColor;
  final double? menuWidth;

  double get _estimatedHeight {
    double height = 0;
    for (final entry in entries) {
      if (entry is MacosContextMenuDivider<T>) {
        height += 10;
      } else if (entry is MacosContextMenuLabel<T>) {
        height += 28;
      } else {
        height += 32;
      }
    }
    return height + 16; // menu padding
  }

  @override
  State<_MacosContextMenuOverlay<T>> createState() =>
      _MacosContextMenuOverlayState<T>();
}

class _MacosContextMenuOverlayState<T>
    extends State<_MacosContextMenuOverlay<T>> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    final macTheme = MacosTheme.of(context);
    final pulldownTheme = macTheme.pulldownButtonTheme;
    final backgroundColor =
        widget.backgroundColor ??
        pulldownTheme.pulldownColor ??
        (macTheme.brightness == Brightness.dark
            ? const Color(0xFF2B2B2F)
            : const Color(0xFFF2F2F7));
    final borderColor =
        widget.borderColor ??
        macTheme.dividerColor.withValues(
          alpha: macTheme.brightness == Brightness.dark ? 0.6 : 0.4,
        );
    final highlightColor =
        widget.highlightColor ??
        (macTheme.brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.08));

    final menuWidth = widget.menuWidth ?? 280.0;
    final menuHeight = widget._estimatedHeight;

    double left = widget.position.dx;
    double top = widget.position.dy;

    left = math.min(
      math.max(12, left),
      math.max(12, widget.overlaySize.width - menuWidth - 12),
    );
    top = math.min(
      math.max(12, top),
      math.max(12, widget.overlaySize.height - menuHeight - 12),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismissed,
            onSecondaryTapUp: (_) => widget.onDismissed(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: RepaintBoundary(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: macTheme.brightness == Brightness.dark
                          ? 0.65
                          : 0.25,
                    ),
                    blurRadius: 18,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: menuWidth,
                    maxWidth: menuWidth,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < widget.entries.length; i++)
                        _buildEntry(
                          context,
                          widget.entries[i],
                          i,
                          highlightColor,
                          macTheme,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEntry(
    BuildContext context,
    MacosContextMenuEntry<T> entry,
    int index,
    Color highlightColor,
    MacosThemeData macTheme,
  ) {
    final typography = macTheme.typography;

    if (entry is MacosContextMenuDivider<T>) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: Divider(height: 1, color: macTheme.dividerColor),
      );
    }
    if (entry is MacosContextMenuLabel<T>) {
      final color =
          entry.color ??
          (macTheme.brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.75)
              : const Color(0xFF0B0B0F).withValues(alpha: 0.75));
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            if (entry.icon != null) ...[
              Icon(entry.icon, size: 14, color: color),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                entry.label,
                style: typography.caption1.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    final item = entry as MacosContextMenuItem<T>;
    final hovered = _hoveredIndex == index && item.enabled;
    final baseTextColor =
        widget.textColor ??
        (item.destructive
            ? const Color(0xFFDA3E52)
            : (macTheme.brightness == Brightness.dark
                  ? Colors.white
                  : const Color(0xFF0B0B0F)));
    final shortcutColor =
        widget.shortcutColor ?? baseTextColor.withValues(alpha: 0.65);
    Color effectiveTextColor = item.enabled
        ? baseTextColor
        : baseTextColor.withValues(alpha: 0.4);
    Color effectiveShortcutColor = item.enabled
        ? shortcutColor
        : shortcutColor.withValues(alpha: 0.4);
    FontWeight fontWeight = item.selected ? FontWeight.w600 : FontWeight.w500;
    if (item.selected) {
      final accent =
          (item.activeColor ?? widget.textColor) ?? const Color(0xFF0A84FF);
      effectiveTextColor = accent;
      effectiveShortcutColor = accent.withValues(alpha: 0.8);
    }

    return MouseRegion(
      onEnter: (_) {
        if (item.enabled) {
          setState(() => _hoveredIndex = index);
        }
      },
      onExit: (_) {
        if (_hoveredIndex == index) {
          setState(() => _hoveredIndex = null);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: item.enabled ? () => widget.onSelected(item.value) : null,
        child: Container(
          height: 32,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: hovered ? highlightColor : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 16, color: effectiveTextColor),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  item.label,
                  style: typography.body.copyWith(
                    color: effectiveTextColor,
                    fontWeight: fontWeight,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              if (item.shortcut != null)
                Text(
                  item.shortcut!,
                  style: typography.caption1.copyWith(
                    color: effectiveShortcutColor,
                    decoration: TextDecoration.none,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
