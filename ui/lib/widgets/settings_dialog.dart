import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/theme_notifier.dart';
import '../core/models/traffic_state.dart';
import '../core/utils/system_proxy_service.dart';
import 'breakpoint_rules_dialog.dart';
import 'confirmation_dialog.dart';
import 'dialog_styles.dart';
import 'macos_button.dart';

class SettingsDialog extends StatelessWidget {
  const SettingsDialog._({required this.style, this.initialIndex = 0});

  final BreakpointDialogStyle style;
  final int initialIndex;

  static Future<void> show(BuildContext context, {int initialIndex = 0}) {
    final targetStyle = Platform.isMacOS
        ? BreakpointDialogStyle.macos
        : Platform.isWindows
        ? BreakpointDialogStyle.windows
        : BreakpointDialogStyle.material;

    if (targetStyle == BreakpointDialogStyle.macos) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final macTheme = MacosThemeData(
        brightness: isDark ? Brightness.dark : Brightness.light,
      );
      return showDialog(
        context: context,
        builder: (_) => MacosTheme(
          data: macTheme,
          child: SettingsDialog._(
            style: targetStyle,
            initialIndex: initialIndex,
          ),
        ),
      );
    }

    if (targetStyle == BreakpointDialogStyle.windows) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final fluentTheme = isDark
          ? fluent.FluentThemeData.dark()
          : fluent.FluentThemeData.light();
      return showDialog(
        context: context,
        builder: (_) => fluent.FluentTheme(
          data: fluentTheme,
          child: SettingsDialog._(
            style: targetStyle,
            initialIndex: initialIndex,
          ),
        ),
      );
    }

    return showDialog(
      context: context,
      builder: (_) => SettingsDialog._(
        style: BreakpointDialogStyle.material,
        initialIndex: initialIndex,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;
    final trafficState = context.watch<TrafficState>();

    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;

    final body = SizedBox(
      width: 760,
      height: 560,
      child: DefaultTabController(
        initialIndex: initialIndex,
        length: 4,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, isDark),
              const SizedBox(height: 12),
              _buildTabBar(isDark),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.only(top: 8),
                      child: _GeneralContent(isDark: isDark),
                    ),
                    SingleChildScrollView(
                      padding: const EdgeInsets.only(top: 8),
                      child: _CertificateContent(
                        isDark: isDark,
                        status: trafficState.certStatus,
                        storagePath: trafficState.storagePath,
                      ),
                    ),
                    _BreakpointsTab(isDark: isDark, style: style),
                    _McpContent(isDark: isDark),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    switch (style) {
      case BreakpointDialogStyle.macos:
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 60,
            vertical: 60,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor, width: 0.8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.2),
                  blurRadius: 30,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: body,
          ),
        );
      case BreakpointDialogStyle.windows:
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 120,
            vertical: 70,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.15),
                  blurRadius: 24,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: body,
          ),
        );
      case BreakpointDialogStyle.material:
        return Dialog(
          backgroundColor: surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: borderColor),
          ),
          child: body,
        );
    }
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    final textSecondary = DialogStyles.subtitle(isDark).color;

    return Row(
      children: [
        Expanded(child: Text('Settings', style: DialogStyles.title(isDark))),
        if (Platform.isMacOS)
          MacosIconButton(
            icon: Icon(Icons.close, color: textSecondary, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
            boxConstraints: const BoxConstraints(minHeight: 26, minWidth: 26),
          )
        else if (Platform.isWindows)
          fluent.IconButton(
            icon: Icon(Icons.close, color: textSecondary, size: 18),
            onPressed: () => Navigator.of(context).maybePop(),
          )
        else
          IconButton(
            icon: Icon(Icons.close, color: textSecondary),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
      ],
    );
  }

  Widget _buildTabBar(bool isDark) {
    final selected = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final unselected = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final indicatorColor = isDark ? AppColors.primaryLight : AppColors.primary;

    return TabBar(
      labelColor: selected,
      unselectedLabelColor: unselected,
      labelStyle: DialogStyles.tabLabel(isDark),
      unselectedLabelStyle: DialogStyles.tabLabelInactive(isDark),
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: indicatorColor, width: 2),
        insets: const EdgeInsets.symmetric(horizontal: 16),
      ),
      tabs: const [
        Tab(text: 'General'),
        Tab(text: 'Certificate'),
        Tab(text: 'Breakpoints'),
        Tab(text: 'MCP'),
      ],
    );
  }
}

class _GeneralContent extends StatelessWidget {
  final bool isDark;

  const _GeneralContent({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final state = context.watch<TrafficState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Clear traffic on quit setting
        Row(
          children: [
            Icon(Icons.delete_sweep_outlined, size: 18, color: textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Clear traffic on quit',
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'If enabled, all captured requests are wiped when the app closes.',
                    style: TextStyle(color: textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (Platform.isMacOS)
              MacosSwitch(
                value: state.clearOnQuit,
                onChanged: (value) =>
                    context.read<TrafficState>().setClearOnQuit(value),
              )
            else if (Platform.isWindows)
              fluent.ToggleSwitch(
                checked: state.clearOnQuit,
                onChanged: (value) =>
                    context.read<TrafficState>().setClearOnQuit(value),
              )
            else
              Switch(
                value: state.clearOnQuit,
                onChanged: (value) =>
                    context.read<TrafficState>().setClearOnQuit(value),
              ),
          ],
        ),
      ],
    );
  }
}

class _BreakpointsTab extends StatelessWidget {
  final bool isDark;
  final BreakpointDialogStyle style;

  const _BreakpointsTab({required this.isDark, required this.style});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: BreakpointRulesContent(
        style: style,
        showHeader: false,
        showCloseButton: false,
      ),
    );
  }
}

class _CertificateContent extends StatefulWidget {
  final bool isDark;
  final CertificateStatus status;
  final String? storagePath;

  const _CertificateContent({
    required this.isDark,
    required this.status,
    required this.storagePath,
  });

  @override
  State<_CertificateContent> createState() => _CertificateContentState();
}

class _CertificateContentState extends State<_CertificateContent> {
  bool _loading = false;
  String? _errorMessage;
  bool _hasPem = false;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  @override
  void didUpdateWidget(covariant _CertificateContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.storagePath != oldWidget.storagePath ||
        widget.status != oldWidget.status) {
      _loadDetails();
    }
  }

  Future<void> _loadDetails() async {
    final storagePath = widget.storagePath;
    if (storagePath == null) {
      setState(() {
        _loading = false;
        _hasPem = false;
        _errorMessage = 'Start the proxy to generate the certificate.';
      });
      return;
    }

    final certPath = '$storagePath/${SystemProxyService.caFileName}';
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final file = File(certPath);
      final exists = await file.exists();
      if (!mounted) return;
      setState(() {
        _hasPem = exists;
        _loading = false;
        _errorMessage = exists ? null : 'Certificate file not found.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasPem = false;
        _loading = false;
        _errorMessage = 'Failed to locate certificate.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textPrimary = widget.isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = widget.isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final installed =
        widget.status != CertificateStatus.notInstalled && _hasPem;
    final statusColor = widget.status == CertificateStatus.trusted
        ? AppColors.success
        : widget.status == CertificateStatus.notInstalled
        ? AppColors.clientError
        : AppColors.redirect;

    String statusText;
    switch (widget.status) {
      case CertificateStatus.notInstalled:
        statusText = 'Not Installed';
        break;
      case CertificateStatus.mismatch:
        statusText = 'Installed (Mismatch)';
        break;
      case CertificateStatus.notTrusted:
        statusText = 'Installed (Not Trusted)';
        break;
      case CertificateStatus.trusted:
        statusText = 'Installed';
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Status row
        Row(
          children: [
            Icon(
              installed ? Icons.verified_user : Icons.security,
              size: 18,
              color: statusColor,
            ),
            const SizedBox(width: 8),
            Text(
              'TLS Certificate',
              style: TextStyle(
                color: textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 8),
            if (_loading)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(
                '($statusText)',
                style: TextStyle(color: statusColor, fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // Description
        Text(
          _getDescription(),
          style: TextStyle(color: textSecondary, fontSize: 12),
        ),

        const SizedBox(height: 12),
        // Certificate Name Hint
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.badge_outlined, size: 14, color: textSecondary),
              const SizedBox(width: 8),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Certificate Name: ',
                      style: TextStyle(color: textSecondary),
                    ),
                    TextSpan(
                      text: 'Cheddar Proxy CA',
                      style: TextStyle(
                        color: textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),

        // Error message
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.info_outline, size: 14, color: textSecondary),
              const SizedBox(width: 6),
              Text(
                _errorMessage!,
                style: TextStyle(color: textSecondary, fontSize: 11),
              ),
            ],
          ),
        ],

        const SizedBox(height: 16),

        // Actions
        Row(
          children: [
            if (Platform.isMacOS)
              MacOSButton(
                label: 'Open Keychain',
                onPressed: _openKeychain,
                isPrimary: false,
                isDark: widget.isDark,
                icon: Icons.vpn_key,
              )
            else if (Platform.isWindows)
              fluent.Button(
                onPressed: _openKeychain,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.vpn_key, size: 16, color: textSecondary),
                    const SizedBox(width: 8),
                    Text(
                      'Open Certificate Manager',
                      style: TextStyle(color: textPrimary),
                    ),
                  ],
                ),
              )
            else
              TextButton.icon(
                onPressed: _openKeychain,
                icon: Icon(Icons.vpn_key, size: 14, color: textSecondary),
                label: Text(
                  'Open Certificate Manager',
                  style: TextStyle(color: textPrimary, fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
            const Spacer(),
            if (widget.status != CertificateStatus.trusted)
              if (Platform.isMacOS)
                MacOSButton(
                  label: 'Trust Certificate',
                  onPressed: _trustCertificate,
                  isPrimary: true,
                  isDark: widget.isDark,
                  icon: Icons.verified_user,
                )
              else if (Platform.isWindows)
                fluent.FilledButton(
                  onPressed: _trustCertificate,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.verified_user, size: 16),
                      const SizedBox(width: 8),
                      const Text('Trust Certificate'),
                    ],
                  ),
                )
              else
                TextButton.icon(
                  onPressed: _trustCertificate,
                  icon: Icon(
                    Icons.verified_user,
                    size: 14,
                    color: AppColors.primary,
                  ),
                  label: Text(
                    'Trust Certificate',
                    style: TextStyle(color: AppColors.primary, fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
          ],
        ),
      ],
    );
  }

  String _getDescription() {
    switch (widget.status) {
      case CertificateStatus.notInstalled:
        return 'Install and trust the CA certificate to inspect HTTPS traffic.';
      case CertificateStatus.mismatch:
        return 'Trusted certificate does not match the on-disk CA. Reinstall to fix HTTPS interception.';
      case CertificateStatus.notTrusted:
        return 'Certificate is installed but not trusted. Trust it to enable HTTPS inspection.';
      case CertificateStatus.trusted:
        return 'HTTPS interception is ready.';
    }
  }

  Future<void> _openKeychain() async {
    final success = await SystemProxyService.viewCertificateInKeychain();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? 'Opening certificate manager...' : 'Could not open.',
        ),
      ),
    );
  }

  Future<void> _trustCertificate() async {
    final trafficState = context.read<TrafficState>();
    final storagePath = trafficState.storagePath;
    if (storagePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Storage path unavailable.')),
      );
      return;
    }
    final certPath = '$storagePath/${SystemProxyService.caFileName}';

    // If mismatch or not trusted, remove any existing CA before reinstalling
    await SystemProxyService.removeExistingCertificate();

    final installed =
        await SystemProxyService.installCertificateToLoginKeychain(certPath);
    if (!installed) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not install certificate.')),
      );
      return;
    }

    final success = await SystemProxyService.trustAndImportCertificate(
      certPath,
    );
    await trafficState.refreshCertificateStatusNow();
    await _loadDetails();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? 'Certificate trust requested.' : 'Could not trust.',
        ),
      ),
    );
  }
}

class _McpContent extends StatefulWidget {
  final bool isDark;

  const _McpContent({required this.isDark});

  @override
  State<_McpContent> createState() => _McpContentState();
}

class _McpContentState extends State<_McpContent> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<TrafficState>();
      if (state.storagePath != null &&
          state.mcpToken == null &&
          !state.isMcpTokenLoading) {
        state.loadMcpToken();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TrafficState>();
    final textPrimary = widget.isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = widget.isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final statusColor = state.isMcpServerRunning
        ? AppColors.success
        : textSecondary;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status and toggle row
          Row(
            children: [
              Icon(
                state.isMcpServerRunning ? Icons.hub : Icons.hub_outlined,
                size: 18,
                color: statusColor,
              ),
              const SizedBox(width: 8),
              Text(
                'MCP Server',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                state.isMcpServerRunning ? '(Running)' : '(Stopped)',
                style: TextStyle(color: statusColor, fontSize: 12),
              ),
              const Spacer(),
              if (state.isMcpToggleInProgress)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (Platform.isMacOS)
                MacosSwitch(
                  value: state.isMcpServerRunning,
                  onChanged: (value) => state.toggleMcpServer(enable: value),
                )
              else if (Platform.isWindows)
                fluent.ToggleSwitch(
                  checked: state.isMcpServerRunning,
                  onChanged: (value) => state.toggleMcpServer(enable: value),
                )
              else
                Switch(
                  value: state.isMcpServerRunning,
                  onChanged: (value) => state.toggleMcpServer(enable: value),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Auto-start option
          _buildCheckboxRow(
            label: 'Enable on startup',
            value: state.autoEnableMcp,
            onChanged: (value) => state.setAutoEnableMcp(value ?? false),
            textColor: textPrimary,
          ),

          const SizedBox(height: 6),
          _buildCheckboxRow(
            label:
                'Allow writes (risky: enables replay, breakpoints, system proxy changes)',
            value: state.mcpAllowWrites,
            onChanged: (value) => state.setMcpAllowWrites(value ?? false),
            textColor: textPrimary,
          ),

          const SizedBox(height: 6),
          _buildCheckboxRow(
            label:
                'Require approval for writes (rejects MCP mutations unless disabled)',
            value: state.mcpRequireApproval,
            onChanged: state.mcpAllowWrites
                ? (value) => state.setMcpRequireApproval(value ?? false)
                : null,
            textColor: state.mcpAllowWrites ? textPrimary : textSecondary,
          ),

          if (state.isMcpServerRunning) ...[
            const SizedBox(height: 16),
            Text(
              'Auth Token',
              style: TextStyle(
                color: textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Builder(
              builder: (_) {
                if (state.isMcpTokenLoading) {
                  return const SizedBox(
                    height: 32,
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                if (state.mcpTokenError != null) {
                  return Text(
                    state.mcpTokenError!,
                    style: TextStyle(
                      color: AppColors.clientError,
                      fontSize: 11,
                    ),
                  );
                }
                if (state.mcpToken != null) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              state.mcpToken!,
                              style: TextStyle(
                                color: widget.isDark
                                    ? const Color(0xFF9CDCFE)
                                    : const Color(0xFF0451A5),
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          if (Platform.isMacOS) ...[
                            MacosIconButton(
                              icon: const Icon(Icons.copy, size: 14),
                              onPressed: () => _copyToken(state.mcpToken!),
                              boxConstraints: const BoxConstraints(
                                minHeight: 26,
                                minWidth: 26,
                              ),
                            ),
                            const SizedBox(width: 8),
                            MacOSButton(
                              label: 'Regenerate',
                              onPressed: () => _regenerateToken(state),
                              isPrimary: false,
                              isDark: widget.isDark,
                            ),
                          ] else if (Platform.isWindows) ...[
                            fluent.IconButton(
                              icon: const Icon(Icons.copy, size: 14),
                              onPressed: () => _copyToken(state.mcpToken!),
                            ),
                            const SizedBox(width: 8),
                            fluent.Button(
                              onPressed: () => _regenerateToken(state),
                              child: const Text('Regenerate'),
                            ),
                          ] else ...[
                            IconButton(
                              icon: Icon(
                                Icons.copy,
                                size: 14,
                                color: textSecondary,
                              ),
                              tooltip: 'Copy token',
                              onPressed: () => _copyToken(state.mcpToken!),
                            ),
                            TextButton(
                              style: DialogButtonStyles.secondary(
                                widget.isDark,
                              ),
                              onPressed: () => _regenerateToken(state),
                              child: const Text('Regenerate'),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Rotating the token disconnects MCP clients. Paste the updated value into your AI IDE/agent config.',
                        style: TextStyle(color: textSecondary, fontSize: 11),
                      ),
                    ],
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ],

          // MCP Config JSON
          const SizedBox(height: 16),
          if (state.isMcpServerRunning) ...[
            _McpConfigBlock(
              isDark: widget.isDark,
              socketPath: state.mcpSocketPath,
              authToken: state.mcpToken,
            ),
          ],

          // Error message
          if (state.mcpLastError != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 14,
                  color: AppColors.clientError,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    state.mcpLastError!,
                    style: TextStyle(
                      color: AppColors.clientError,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _copyToken(String token) {
    Clipboard.setData(ClipboardData(text: token));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Token copied')));
  }

  Future<void> _regenerateToken(TrafficState state) async {
    final confirmed = await showConfirmation(
      context: context,
      title: 'Regenerate MCP Token',
      message:
          'All connected MCP clients will need to update their configuration.',
      confirmLabel: 'Regenerate',
      isDestructive: false,
    );
    if (!confirmed) return;
    await state.loadMcpToken(regenerate: true);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('MCP token regenerated')));
  }

  Widget _buildCheckboxRow({
    required String label,
    required bool value,
    required ValueChanged<bool?>? onChanged,
    required Color textColor,
  }) {
    final checkbox = Platform.isMacOS
        ? MacosCheckbox(value: value, onChanged: onChanged)
        : Platform.isWindows
        ? fluent.Checkbox(checked: value, onChanged: onChanged)
        : SizedBox(
            width: 18,
            height: 18,
            child: Checkbox(
              value: value,
              onChanged: onChanged,
              activeColor: AppColors.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          );

    return Row(
      children: [
        checkbox,
        const SizedBox(width: 8),
        Expanded(
          child: GestureDetector(
            onTap: onChanged != null ? () => onChanged(!value) : null,
            child: Text(
              label,
              style: TextStyle(color: textColor, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class _McpConfigBlock extends StatefulWidget {
  final bool isDark;
  final String? socketPath;
  final String? authToken;

  const _McpConfigBlock({
    required this.isDark,
    this.socketPath,
    this.authToken,
  });

  @override
  State<_McpConfigBlock> createState() => _McpConfigBlockState();
}

class _McpConfigBlockState extends State<_McpConfigBlock> {
  bool _isAddingToCursor = false;

  // Resolve an absolute path to the MCP bridge if available so users don't need PATH tweaks.
  String _resolveBridgeCommand() {
    final candidates = <String>[];
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir/cheddarproxy_mcp_bridge');
      candidates.add('$exeDir/cheddarproxy_mcp_bridge.exe');
      candidates.add(
        '${Directory(exeDir).parent.path}/cheddarproxy_mcp_bridge',
      );
      candidates.add(
        '${Directory(exeDir).parent.path}/cheddarproxy_mcp_bridge.exe',
      );
    } catch (_) {
      // ignore
    }

    final cwd = Directory.current.path;
    candidates.add(
      '$cwd/macos/cheddarproxy_mcp_bridge',
    ); // staged by scripts/build_rust.sh
    candidates.add('$cwd/target/release/cheddarproxy_mcp_bridge');
    candidates.add('$cwd/core/target/release/cheddarproxy_mcp_bridge');
    candidates.add('$cwd/target/release/cheddarproxy_mcp_bridge.exe');
    candidates.add('$cwd/core/target/release/cheddarproxy_mcp_bridge.exe');

    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return 'cheddarproxy_mcp_bridge';
  }

  bool get _isWindows => Platform.isWindows;

  String get _configJson {
    final token = widget.authToken ?? '<MCP_TOKEN>';
    final bridgeCmd = _resolveBridgeCommand();
    return buildMcpConfigJson(
      isWindows: _isWindows,
      socketPath: widget.socketPath,
      authToken: token,
      bridgeCmd: bridgeCmd,
    );
  }

  /// Build the servers-only map for merging into Cursor config.
  Map<String, dynamic> _buildServersMap() {
    final token = widget.authToken ?? '<MCP_TOKEN>';
    final bridgeCmd = _resolveBridgeCommand();

    if (_isWindows) {
      final raw = widget.socketPath ?? '127.0.0.1:<PORT>';
      final stripped = raw.startsWith('tcp://') ? raw.substring(6) : raw;
      final parts = stripped.split(':');
      final port = parts.isNotEmpty ? parts.removeLast() : '<PORT>';
      final host = parts.isEmpty ? '127.0.0.1' : parts.join(':');
      final portNum = int.tryParse(port);
      final addr = '$host:$port';

      return {
        'cheddarproxy-stdio': {
          'command': bridgeCmd,
          'args': ['--tcp', addr],
          'auth': {'type': 'bearer', 'token': token},
        },
        'cheddarproxy-tcp': {
          'transport': {'type': 'tcp', 'host': host, 'port': portNum ?? port},
          'auth': {'type': 'bearer', 'token': token},
        },
      };
    } else {
      final path = widget.socketPath ?? '/tmp/cheddarproxy_mcp.sock';
      return {
        'cheddarproxy-stdio': {
          'command': bridgeCmd,
          'args': ['--socket', path],
          'auth': {'type': 'bearer', 'token': token},
        },
        'cheddarproxy-socket': {
          'transport': {'type': 'unix', 'path': path},
          'auth': {'type': 'bearer', 'token': token},
        },
      };
    }
  }

  /// Get Cursor's mcp.json path
  String? _getCursorConfigPath() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return null;
    return '$home/.cursor/mcp.json';
  }

  /// Safely merge Cheddar Proxy's MCP config into Cursor's mcp.json.
  /// Only adds/updates cheddarproxy-* keys, leaves all other servers untouched.
  Future<void> _addToCursor() async {
    setState(() => _isAddingToCursor = true);

    try {
      final configPath = _getCursorConfigPath();
      if (configPath == null) {
        _showError('Could not determine home directory');
        return;
      }

      // Ensure .cursor directory exists
      final cursorDir = Directory(configPath).parent;
      if (!await cursorDir.exists()) {
        await cursorDir.create(recursive: true);
      }

      final file = File(configPath);
      Map<String, dynamic> existingConfig = {};

      // Read existing config if it exists
      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          if (content.trim().isNotEmpty) {
            existingConfig = jsonDecode(content) as Map<String, dynamic>;
          }
        } catch (e) {
          _showError('Cursor config has invalid JSON. Please fix it manually.');
          return;
        }
      }

      // Ensure mcpServers key exists
      existingConfig['mcpServers'] ??= <String, dynamic>{};

      // Merge our servers (only touches cheddarproxy-* keys)
      final ourServers = _buildServersMap();
      (existingConfig['mcpServers'] as Map<String, dynamic>).addAll(ourServers);

      // Write back with pretty formatting
      final encoder = const JsonEncoder.withIndent('  ');
      await file.writeAsString(encoder.convert(existingConfig));

      // Attempt to launch Cursor so the config is picked up immediately
      await _launchCursorIfAvailable();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Added to Cursor! MCP server should appear momentarily.',
          ),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      _showError('Failed to add to Cursor: $e');
    } finally {
      if (mounted) {
        setState(() => _isAddingToCursor = false);
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.clientError),
    );
    setState(() => _isAddingToCursor = false);
  }

  Future<void> _launchCursorIfAvailable() async {
    if (!Platform.isMacOS) return;
    try {
      final result = await Process.run('open', ['-a', 'Cursor']);
      if (result.exitCode != 0) {
        _showError('Cursor is not installed or could not be opened.');
      }
    } catch (_) {
      _showError('Cursor is not installed or could not be opened.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final textSecondary = widget.isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    // Cursor button styling
    const cursorButtonBg = Color(0xFFF2F2F2); // Light grey background
    const cursorButtonText = Color(0xFF111111);
    const cursorIconAsset = 'assets/icon/cursor_logo.png';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Add to Cursor button - prominent, above JSON
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isDark
                ? const Color(0xFF1E1E1E)
                : const Color(0xFFF5F5F5),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            border: Border.all(
              color: widget.isDark
                  ? AppColors.surfaceBorder
                  : AppColorsLight.surfaceBorder,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'IDE Configuration',
                  style: TextStyle(
                    color: widget.isDark
                        ? AppColors.textPrimary
                        : AppColorsLight.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              // Copy button
              _buildSmallButton(
                icon: Icons.copy,
                tooltip: 'Copy config',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _configJson));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('MCP config copied')),
                  );
                },
              ),
              const SizedBox(width: 8),
              // Add to Cursor button - Cursor styled
              _isAddingToCursor
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: cursorButtonBg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: widget.isDark
                              ? AppColors.surfaceBorder
                              : AppColorsLight.surfaceBorder,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: cursorButtonText,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Adding...',
                            style: TextStyle(
                              color: cursorButtonText,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Material(
                      color: cursorButtonBg,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        onTap: _addToCursor,
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Cursor brand icon
                              Image.asset(
                                cursorIconAsset,
                                width: 16,
                                height: 16,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Add to Cursor',
                                style: TextStyle(
                                  color: cursorButtonText,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ],
          ),
        ),
        // Config JSON block - connected to header
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: widget.isDark
                ? const Color(0xFF1E1E1E)
                : const Color(0xFFF5F5F5),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(6),
            ),
            border: Border(
              left: BorderSide(
                color: widget.isDark
                    ? AppColors.surfaceBorder
                    : AppColorsLight.surfaceBorder,
              ),
              right: BorderSide(
                color: widget.isDark
                    ? AppColors.surfaceBorder
                    : AppColorsLight.surfaceBorder,
              ),
              bottom: BorderSide(
                color: widget.isDark
                    ? AppColors.surfaceBorder
                    : AppColorsLight.surfaceBorder,
              ),
            ),
          ),
          child: SelectableText(
            _configJson,
            style: TextStyle(
              color: widget.isDark
                  ? const Color(0xFF9CDCFE)
                  : const Color(0xFF0451A5),
              fontSize: 11,
              fontFamily: 'monospace',
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Helper text
        Text(
          'Merges into ~/.cursor/mcp.json • existing servers preserved',
          style: TextStyle(color: textSecondary, fontSize: 10),
        ),
      ],
    );
  }

  Widget _buildSmallButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 14, color: Colors.white.withOpacity(0.7)),
          ),
        ),
      ),
    );
  }
}

/// Build the MCP config JSON snippet for UI copy actions.
/// Exposed for tests to verify platform-specific generation.
@visibleForTesting
String buildMcpConfigJson({
  required bool isWindows,
  String? socketPath,
  String? authToken,
  String bridgeCmd = 'cheddarproxy_mcp_bridge',
}) {
  final token = authToken ?? '<MCP_TOKEN>';

  if (isWindows) {
    final raw = socketPath ?? '127.0.0.1:<PORT>';
    final stripped = raw.startsWith('tcp://') ? raw.substring(6) : raw;
    final parts = stripped.split(':');
    final port = parts.isNotEmpty ? parts.removeLast() : '<PORT>';
    final host = parts.isEmpty ? '127.0.0.1' : parts.join(':');
    final portLiteral = int.tryParse(port) != null ? port : '"$port"';
    final addr = '$host:$port';

    return '''
{
  "mcpServers": {
    "cheddarproxy-stdio": {
      "command": "$bridgeCmd",
      "args": ["--tcp", "$addr"],
      "auth": {
        "type": "bearer",
        "token": "$token"
      }
    },
    "cheddarproxy-tcp": {
      "transport": {
        "type": "tcp",
        "host": "$host",
        "port": $portLiteral
      },
      "auth": {
        "type": "bearer",
        "token": "$token"
      }
    }
  }
}''';
  } else {
    final path = socketPath ?? '/tmp/cheddarproxy_mcp.sock';
    return '''
{
  "mcpServers": {
    "cheddarproxy-stdio": {
      "command": "$bridgeCmd",
      "args": ["--socket", "$path"],
      "auth": {
        "type": "bearer",
        "token": "$token"
      }
    },
    "cheddarproxy-socket": {
      "transport": {
        "type": "unix",
        "path": "$path"
      },
      "auth": {
        "type": "bearer",
        "token": "$token"
      }
    }
  }
}''';
  }
}
