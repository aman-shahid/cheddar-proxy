import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'about_dialog.dart';
import 'platform_context_menu.dart';

/// Windows-style menu bar using custom context menus
class WindowsMenuBar extends StatelessWidget {
  final bool isDark;
  final Color foregroundColor;
  final VoidCallback? onCheckForUpdates;
  final String? storagePath;

  const WindowsMenuBar({
    super.key,
    required this.isDark,
    required this.foregroundColor,
    this.onCheckForUpdates,
    this.storagePath,
  });

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return const SizedBox.shrink();
    }

    final hoverColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MenuBarButton(
          label: 'File',
          foregroundColor: foregroundColor,
          hoverColor: hoverColor,
          onTap: (position) => _showFileMenu(context, position),
        ),
        _MenuBarButton(
          label: 'Help',
          foregroundColor: foregroundColor,
          hoverColor: hoverColor,
          onTap: (position) => _showHelpMenu(context, position),
        ),
      ],
    );
  }

  void _showFileMenu(BuildContext context, Offset position) async {
    final action = await showPlatformContextMenu<String>(
      context: context,
      position: position,
      minWidth: 120,
      entries: const [PlatformContextMenuItem(value: 'exit', label: 'Exit')],
    );

    if (action == 'exit') {
      exit(0);
    }
  }

  void _showHelpMenu(BuildContext context, Offset position) async {
    final action = await showPlatformContextMenu<String>(
      context: context,
      position: position,
      minWidth: 200,
      entries: const [
        PlatformContextMenuItem(value: 'updates', label: 'Check for Updates'),
        PlatformContextMenuDivider(),
        PlatformContextMenuItem(value: 'docs', label: 'Documentation'),
        PlatformContextMenuItem(value: 'issue', label: 'Report Issue'),
        PlatformContextMenuItem(value: 'logs', label: 'Open Logs Folder'),
        PlatformContextMenuDivider(),
        PlatformContextMenuItem(value: 'about', label: 'About Cheddar Proxy'),
      ],
    );

    if (action == null || !context.mounted) return;

    switch (action) {
      case 'updates':
        onCheckForUpdates?.call();
      case 'docs':
        launchUrl(Uri.parse('https://github.com/aman-shahid/netscope#readme'));
      case 'issue':
        launchUrl(
          Uri.parse(
            'https://github.com/aman-shahid/netscope/issues/new/choose',
          ),
        );
      case 'logs':
        _openLogsFolder();
      case 'about':
        CheddarProxyAboutDialog.show(context);
    }
  }

  void _openLogsFolder() {
    if (storagePath == null || storagePath!.isEmpty) {
      return;
    }
    final dir = Directory('$storagePath/logs');
    if (!dir.existsSync()) {
      return;
    }
    launchUrl(Uri.file(dir.path));
  }
}

/// Individual menu bar button
class _MenuBarButton extends StatefulWidget {
  final String label;
  final Color foregroundColor;
  final Color hoverColor;
  final void Function(Offset position) onTap;

  const _MenuBarButton({
    required this.label,
    required this.foregroundColor,
    required this.hoverColor,
    required this.onTap,
  });

  @override
  State<_MenuBarButton> createState() => _MenuBarButtonState();
}

class _MenuBarButtonState extends State<_MenuBarButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: () {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final origin = box.localToGlobal(Offset.zero);
          final position = Offset(origin.dx, origin.dy + box.size.height);
          widget.onTap(position);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _isHovered ? widget.hoverColor : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            widget.label,
            style: TextStyle(color: widget.foregroundColor, fontSize: 12),
          ),
        ),
      ),
    );
  }
}
