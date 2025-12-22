import 'dart:async';
import 'dart:io' show Directory, Platform;
// ignore_for_file: use_build_context_synchronously

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_notifier.dart';
import '../core/models/traffic_state.dart';
import '../core/utils/system_proxy_service.dart';
import '../core/utils/logger_service.dart';
import '../features/composer/composer_state.dart';
import 'about_dialog.dart';
import 'certificate_dialog.dart';
import 'confirmation_dialog.dart';
import 'platform_context_menu.dart';
import 'settings_dialog.dart';

/// Toolbar at the top of the app
class AppToolbar extends StatelessWidget {
  const AppToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;
    final isMac = Platform.isMacOS;

    // Get theme-aware colors
    final backgroundColor = isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final dividerColor = borderColor.withValues(alpha: isDark ? 0.35 : 0.6);

    const horizontalPadding = EdgeInsets.symmetric(horizontal: 12);
    final toolbarHeight = isMac ? 52.0 : 48.0;

    final toolbar = Consumer<TrafficState>(
      builder: (context, state, _) {
        return Container(
          height: toolbarHeight,
          padding: horizontalPadding,
          decoration: BoxDecoration(
            color: backgroundColor,
            border: Border(bottom: BorderSide(color: dividerColor)),
          ),
          child: Row(
            children: [
              // Recording toggle
              _ToolbarButton(
                icon: state.isRecording ? Icons.pause : Icons.play_arrow,
                label: state.isRecording ? 'Pause' : 'Record',
                isActive: state.isRecording,
                activeColor: AppColors.success,
                onPressed: state.toggleRecording,
                isDark: isDark,
              ),
              const SizedBox(width: 8),

              // Clear button
              _ToolbarButton(
                icon: Icons.delete_outline,
                label: 'Clear',
                onPressed: state.transactions.isEmpty
                    ? null
                    : () => _showClearConfirmation(context, state, isDark),
                isDark: isDark,
              ),

              const SizedBox(width: 8),

              _SessionMenuButton(state: state, isDark: isDark),

              const SizedBox(width: 8),

              _ToolbarButton(
                icon: state.isMcpServerRunning ? Icons.hub : Icons.hub_outlined,
                label: 'MCP',
                isActive: state.isMcpServerRunning,
                activeColor: AppColors.primary,
                onPressed: () => SettingsDialog.show(context, initialIndex: 3),
                isDark: isDark,
              ),

              const SizedBox(width: 8),

              // Compose button - opens request builder
              Consumer<ComposerState>(
                builder: (context, composerState, _) => _ToolbarButton(
                  icon: Icons.edit_note,
                  label: 'Compose',
                  isActive: composerState.isOpen,
                  activeColor: AppColors.primary,
                  onPressed: () => composerState.toggle(),
                  isDark: isDark,
                ),
              ),

              const SizedBox(width: 8),

              const Spacer(),

              _HelpMenuButton(isDark: isDark, storagePath: state.storagePath),

              const SizedBox(width: 8),

              // Theme toggle button
              _ThemeToggleButton(isDark: isDark),

              const SizedBox(width: 8),

              // Settings button (icon only, includes breakpoint manager)
              _ToolbarButton(
                icon: Icons.settings_outlined,
                label: '',
                onPressed: () => SettingsDialog.show(context),
                isDark: isDark,
              ),
            ],
          ),
        );
      },
    );

    return DragToMoveArea(child: toolbar);
  }

  Future<void> _showClearConfirmation(
    BuildContext context,
    TrafficState state,
    bool isDark,
  ) async {
    final confirmed = await showDeleteConfirmation(
      context: context,
      title: 'Clear All Traffic',
      message:
          'This will remove all captured requests.\nThis action cannot be undone.',
      confirmLabel: 'Clear',
    );

    if (confirmed) {
      await state.clearAll();
    }
  }
}

class _HelpMenuButton extends StatelessWidget {
  final bool isDark;
  final String? storagePath;

  const _HelpMenuButton({required this.isDark, required this.storagePath});

  @override
  Widget build(BuildContext context) {
    return _ToolbarButton(
      icon: Icons.help_outline,
      label: 'Help',
      isDark: isDark,
      onPressed: () => _showHelpMenu(context),
    );
  }

  Future<void> _showHelpMenu(BuildContext context) async {
    final action = await showPlatformContextMenu<String>(
      context: context,
      position: Offset.zero,
      entries: const [
        PlatformContextMenuItem(value: 'docs', label: 'Documentation'),
        PlatformContextMenuItem(value: 'issue', label: 'Report Issue'),
        PlatformContextMenuItem(value: 'logs', label: 'Open Logs Folder'),
        PlatformContextMenuDivider(),
        PlatformContextMenuItem(value: 'about', label: 'About Cheddar Proxy'),
      ],
    );

    if (action == null || !context.mounted) return;

    switch (action) {
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
      LoggerService.error('Storage path is not set; cannot open logs folder.');
      return;
    }
    final dir = Directory('$storagePath/logs');
    if (!dir.existsSync()) {
      LoggerService.error('Logs folder not found at ${dir.path}');
      return;
    }
    launchUrl(Uri.file(dir.path));
  }
}

/// Theme toggle button with dropdown
class _ThemeToggleButton extends StatelessWidget {
  final bool isDark;

  const _ThemeToggleButton({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.read<ThemeNotifier>();
    final currentMode = themeNotifier.mode;

    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    final trigger = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_getModeIcon(currentMode), size: 18, color: textSecondary),
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 16, color: textSecondary),
        ],
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          final renderBox = context.findRenderObject() as RenderBox?;
          if (renderBox == null) return;
          final origin = renderBox.localToGlobal(Offset.zero);
          final anchor = Offset(
            origin.dx,
            origin.dy + renderBox.size.height + 6,
          );
          _showThemeMenu(
            context: context,
            position: anchor,
            currentMode: currentMode,
            themeNotifier: themeNotifier,
          );
        },
        child: trigger,
      ),
    );
  }

  Future<void> _showThemeMenu({
    required BuildContext context,
    required Offset position,
    required AppThemeMode currentMode,
    required ThemeNotifier themeNotifier,
  }) async {
    final backgroundColor = AppColors.surface;
    final borderColor = AppColors.surfaceBorder;
    final highlightColor = AppColors.primary.withValues(
      alpha: isDark ? 0.22 : 0.18,
    );

    final entries = [
      _platformThemeEntry(AppThemeMode.light, 'Light', currentMode),
      _platformThemeEntry(AppThemeMode.dark, 'Dark', currentMode),
      _platformThemeEntry(AppThemeMode.darkPlus, 'Dark+', currentMode),
      _platformThemeEntry(AppThemeMode.system, 'System', currentMode),
    ];

    final mode = await showPlatformContextMenu<AppThemeMode>(
      context: context,
      position: position,
      entries: entries,
      minWidth: 100, // Narrow menu for short labels
      macMenuWidth: 140,
      backgroundColor: backgroundColor,
      borderColor: borderColor,
      highlightColor: highlightColor,
    );

    if (mode != null) {
      themeNotifier.setMode(mode);
    }
  }

  PlatformContextMenuItem<AppThemeMode> _platformThemeEntry(
    AppThemeMode mode,
    String label,
    AppThemeMode currentMode,
  ) {
    return PlatformContextMenuItem<AppThemeMode>(
      value: mode,
      label: label,
      icon: _getModeIcon(mode),
      isSelected: currentMode == mode,
    );
  }

  IconData _getModeIcon(AppThemeMode mode) {
    switch (mode) {
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
}

/// Toolbar button widget
class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color? activeColor;
  final VoidCallback? onPressed;
  final bool isDark;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    this.isActive = false,
    this.activeColor,
    required this.onPressed,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final surfaceLight = isDark
        ? AppColors.surfaceLight
        : AppColorsLight.surfaceLight;

    final isDisabled = onPressed == null;
    final baseColor = isActive
        ? (activeColor ?? AppColors.primary)
        : textSecondary;
    final color = isDisabled ? baseColor.withValues(alpha: 0.5) : baseColor;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        hoverColor: isDisabled ? Colors.transparent : surfaceLight,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: label.isEmpty ? 8 : 12,
            vertical: 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _SessionMenuAction { exportAll, exportFiltered, importHar }

enum _CertificateAction { viewKeychain, export }

class _SessionMenuButton extends StatelessWidget {
  final TrafficState state;
  final bool isDark;

  const _SessionMenuButton({required this.state, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    final hasTraffic = state.transactions.isNotEmpty;
    final hasFilter = !state.filter.isEmpty;

    final buttonChild = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: Colors.transparent,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_open, size: 18, color: textSecondary),
          const SizedBox(width: 6),
          Text(
            'Sessions',
            style: TextStyle(
              color: textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 16, color: textSecondary),
        ],
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          final renderBox = context.findRenderObject() as RenderBox?;
          if (renderBox == null) return;
          final origin = renderBox.localToGlobal(Offset.zero);
          final anchor = Offset(
            origin.dx,
            origin.dy + renderBox.size.height + 4,
          );
          _showSessionMenu(
            context: context,
            position: anchor,
            hasTraffic: hasTraffic,
            hasFilter: hasFilter,
            isDark: isDark,
          );
        },
        child: buttonChild,
      ),
    );
  }

  Future<void> _showSessionMenu({
    required BuildContext context,
    required Offset position,
    required bool hasTraffic,
    required bool hasFilter,
    required bool isDark,
  }) async {
    final backgroundColor = AppColors.surface;
    final borderColor = AppColors.surfaceBorder;
    final highlightColor = AppColors.primary.withValues(
      alpha: isDark ? 0.22 : 0.18,
    );
    final textColor = AppColors.textPrimary;
    final shortcutColor = AppColors.textSecondary;

    final action = await showPlatformContextMenu<_SessionMenuAction>(
      context: context,
      position: position,
      entries: [
        PlatformContextMenuItem(
          value: _SessionMenuAction.exportAll,
          label: 'Export all traffic (.har)',
          icon: Icons.save_outlined,
          enabled: hasTraffic,
        ),
        PlatformContextMenuItem(
          value: _SessionMenuAction.exportFiltered,
          label: 'Export filtered view',
          icon: Icons.filter_alt_outlined,
          enabled: hasTraffic && hasFilter,
        ),
        const PlatformContextMenuDivider(),
        const PlatformContextMenuItem(
          value: _SessionMenuAction.importHar,
          label: 'Import HAR session',
          icon: Icons.file_upload_outlined,
        ),
      ],
      backgroundColor: backgroundColor,
      borderColor: borderColor,
      highlightColor: highlightColor,
      textColor: textColor,
      shortcutColor: shortcutColor,
    );

    if (action != null) {
      unawaited(_handleSessionAction(context, action));
    }
  }

  Future<void> _handleSessionAction(
    BuildContext context,
    _SessionMenuAction action,
  ) async {
    switch (action) {
      case _SessionMenuAction.exportAll:
        await _exportHar(context, filteredOnly: false);
        break;
      case _SessionMenuAction.exportFiltered:
        await _exportHar(context, filteredOnly: true);
        break;
      case _SessionMenuAction.importHar:
        await _importHar(context);
        break;
    }
  }

  Future<void> _exportHar(
    BuildContext context, {
    required bool filteredOnly,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final suffix = filteredOnly ? '_filtered' : '';
    final suggestedName = 'cheddar_session${suffix}_$timestamp.har';

    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export HAR',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: ['har'],
      );
      if (path == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Export cancelled')),
        );
        return;
      }

      final count = await state.exportHarToPath(
        outputPath: path,
        filteredOnly: filteredOnly,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Exported $count requests to ${_fileLabel(path)}'),
        ),
      );
    } catch (e, st) {
      LoggerService.error('HAR export failed: $e\n$st');
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _importHar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['har', 'json'],
      );
      if (result == null || result.files.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Import cancelled')),
        );
        return;
      }
      final path = result.files.single.path;
      if (path == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Import path unavailable')),
        );
        return;
      }

      final count = await state.importHarFromFile(path);
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Imported $count requests from ${_fileLabel(path)}'),
        ),
      );
    } catch (e, st) {
      LoggerService.error('HAR import failed: $e\n$st');
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  String _fileLabel(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isNotEmpty ? parts.last : path;
  }
}

/// Context-aware certificate button that shows trust status
class _CertificateButton extends StatefulWidget {
  final bool isDark;
  final String? storagePath;

  const _CertificateButton({required this.isDark, required this.storagePath});

  @override
  State<_CertificateButton> createState() => _CertificateButtonState();
}

class _CertificateButtonState extends State<_CertificateButton> {
  bool _isTrusted = false;
  bool _isChecking = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _checkTrustStatus();
    // Periodically check trust status every 5 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkTrustStatus();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkTrustStatus() async {
    final trusted = await SystemProxyService.isCertificateTrusted();
    if (mounted && trusted != _isTrusted) {
      setState(() {
        _isTrusted = trusted;
        _isChecking = false;
      });
    } else if (mounted && _isChecking) {
      setState(() => _isChecking = false);
    }
  }

  void _onPressed() {
    final certPath = widget.storagePath != null
        ? '${widget.storagePath}/cheddar_proxy_ca.pem'
        : null;

    if (_isTrusted) {
      // Show status popover
      _showTrustedPopover(context, certPath);
    } else if (certPath != null) {
      // Show onboarding dialog
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => CertificateOnboardingDialog(
          certPath: certPath,
          onComplete: () {
            Navigator.of(ctx).pop();
            _checkTrustStatus(); // Refresh status
          },
          onSkip: () => Navigator.of(ctx).pop(),
        ),
      );
    }
  }

  Future<void> _showTrustedPopover(
    BuildContext context,
    String? certPath,
  ) async {
    // Calculate position from render box
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final origin = renderBox.localToGlobal(Offset.zero);
    final position = Offset(origin.dx, origin.dy + renderBox.size.height + 4);

    final entries = <PlatformContextMenuEntry<_CertificateAction>>[
      const PlatformContextMenuLabel(
        label: 'Certificate Trusted',
        icon: Icons.check_circle,
        color: AppColors.success,
      ),
      const PlatformContextMenuDivider(),
      const PlatformContextMenuItem(
        value: _CertificateAction.viewKeychain,
        label: 'View in Keychain',
        icon: Icons.open_in_new,
      ),
      if (certPath != null)
        const PlatformContextMenuItem(
          value: _CertificateAction.export,
          label: 'Export Certificate',
          icon: Icons.download_outlined,
        ),
    ];

    final action = await showPlatformContextMenu<_CertificateAction>(
      context: context,
      position: position,
      entries: entries,
    );

    if (action == null || !context.mounted) return;

    switch (action) {
      case _CertificateAction.viewKeychain:
        SystemProxyService.viewCertificateInKeychain();
      case _CertificateAction.export:
        final state = context.read<TrafficState>();
        state.exportRootCa();
    }
  }

  @override
  Widget build(BuildContext context) {
    final textSecondary = widget.isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final surfaceLight = widget.isDark
        ? AppColors.surfaceLight
        : AppColorsLight.surfaceLight;

    // Determine icon and color based on status
    IconData icon;
    Color color;
    String label;

    if (_isChecking) {
      icon = Icons.security;
      color = textSecondary;
      label = 'Certificate';
    } else if (_isTrusted) {
      icon = Icons.verified_user;
      color = AppColors.success;
      label = 'Certificate';
    } else {
      icon = Icons.warning_amber;
      color = AppColors.clientError;
      label = 'Setup Certificate';
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _isChecking ? null : _onPressed,
        borderRadius: BorderRadius.circular(6),
        hoverColor: surfaceLight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: _isTrusted ? FontWeight.normal : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
