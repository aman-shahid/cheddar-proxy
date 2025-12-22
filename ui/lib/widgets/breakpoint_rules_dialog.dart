import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/theme_notifier.dart';
import '../src/rust/api/proxy_api.dart' as rust_api;
import '../src/rust/models/breakpoint.dart';
import '../src/rust/models/transaction.dart' as rust_models;
import 'dialog_styles.dart';

enum BreakpointDialogStyle { material, macos, windows }

class BreakpointRulesDialog extends StatelessWidget {
  const BreakpointRulesDialog._({required this.style});

  final BreakpointDialogStyle style;

  static Future<void> show(BuildContext context) {
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
          child: BreakpointRulesDialog._(style: targetStyle),
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
          child: BreakpointRulesDialog._(style: targetStyle),
        ),
      );
    }

    return showDialog(
      context: context,
      builder: (_) =>
          const BreakpointRulesDialog._(style: BreakpointDialogStyle.material),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;

    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;

    final content = SizedBox(
      width: 640,
      height: 520,
      child: BreakpointRulesContent(
        style: style,
        showHeader: true,
        showCloseButton: true,
        onClose: () => Navigator.of(context).maybePop(),
      ),
    );

    switch (style) {
      case BreakpointDialogStyle.macos:
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 80,
            vertical: 80,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor, width: 0.8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.18),
                  blurRadius: 28,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: content,
          ),
        );
      case BreakpointDialogStyle.windows:
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 120,
            vertical: 80,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.16),
                  blurRadius: 30,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: content,
          ),
        );
      case BreakpointDialogStyle.material:
        return Dialog(
          backgroundColor: surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: borderColor),
          ),
          child: content,
        );
    }
  }
}

class BreakpointRulesContent extends StatefulWidget {
  const BreakpointRulesContent({
    super.key,
    required this.style,
    this.showHeader = true,
    this.showCloseButton = true,
    this.onClose,
  });

  final BreakpointDialogStyle style;
  final bool showHeader;
  final bool showCloseButton;
  final VoidCallback? onClose;

  @override
  State<BreakpointRulesContent> createState() => _BreakpointRulesContentState();
}

class _BreakpointRulesContentState extends State<BreakpointRulesContent> {
  final ScrollController _scrollController = ScrollController();
  List<BreakpointRule> _rules = [];

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _loadRules() {
    setState(() {
      _rules = rust_api.listBreakpointRules();
    });
  }

  void _deleteRule(String id) {
    rust_api.removeBreakpointRule(id: id);
    _loadRules();
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;

    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    final listView = ListView.separated(
      controller: _scrollController,
      physics: widget.style == BreakpointDialogStyle.macos
          ? const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())
          : const ClampingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: _rules.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        thickness: 1,
        color: borderColor.withValues(alpha: 0.5),
      ),
      itemBuilder: (context, index) {
        final rule = _rules[index];
        return _buildRuleItem(rule, isDark, textPrimary, textSecondary);
      },
    );

    final scrollable = widget.style == BreakpointDialogStyle.macos
        ? MacosScrollbar(controller: _scrollController, child: listView)
        : Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: listView,
          );

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showHeader) ...[
            _buildHeader(
              textPrimary: textPrimary,
              textSecondary: textSecondary,
              isDark: isDark,
            ),
            const SizedBox(height: 12),
          ],
          if (_rules.isNotEmpty) _buildTableHeader(textSecondary),
          if (_rules.isNotEmpty) const SizedBox(height: 6),
          Expanded(
            child: _rules.isEmpty
                ? _buildEmptyState(textSecondary)
                : scrollable,
          ),
        ],
      ),
    );
  }

  Widget _buildHeader({
    required Color textPrimary,
    required Color textSecondary,
    required bool isDark,
  }) {
    final subtitle = widget.style == BreakpointDialogStyle.windows
        ? 'Fluent-style manager for breakpointed traffic'
        : 'Manage active rules for intercepting traffic';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Breakpoint Rules', style: DialogStyles.title(isDark)),
              const SizedBox(height: 4),
              Text(subtitle, style: DialogStyles.subtitle(isDark)),
            ],
          ),
        ),
        if (widget.showCloseButton)
          if (Platform.isMacOS)
            MacosIconButton(
              icon: Icon(Icons.close, color: textSecondary, size: 20),
              onPressed: widget.onClose,
              boxConstraints: const BoxConstraints(minHeight: 26, minWidth: 26),
            )
          else if (Platform.isWindows)
            fluent.IconButton(
              icon: Icon(Icons.close, color: textSecondary, size: 18),
              onPressed: widget.onClose,
            )
          else
            IconButton(
              icon: Icon(Icons.close, color: textSecondary),
              tooltip: 'Close',
              onPressed: widget.onClose,
            ),
      ],
    );
  }

  Widget _buildTableHeader(Color textSecondary) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: textSecondary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              'Method',
              style: TextStyle(
                color: textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 140,
            child: Text(
              'Match',
              style: TextStyle(
                color: textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              'Value',
              style: TextStyle(
                color: textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '',
              textAlign: TextAlign.right,
              style: TextStyle(color: textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(Color textSecondary) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.playlist_remove,
            size: 48,
            color: textSecondary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No active breakpoint rules',
            style: TextStyle(
              color: textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Right-click on a request in the traffic list to add one.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textSecondary.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleItem(
    BreakpointRule rule,
    bool isDark,
    Color textPrimary,
    Color textSecondary,
  ) {
    final methodLabel = rule.method != null
        ? _methodToString(rule.method!)
        : 'Any';
    final methodColor = rule.method != null
        ? AppColors.getMethodColor(methodLabel)
        : textSecondary;

    String matchLabel = 'Any traffic';
    String matchValue = 'All requests';

    if ((rule.pathContains ?? '').isNotEmpty) {
      matchLabel = 'URL contains';
      matchValue = rule.pathContains!;
    } else if ((rule.hostContains ?? '').isNotEmpty) {
      matchLabel = 'Host contains';
      matchValue = rule.hostContains!;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 100,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: methodColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  methodLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: methodColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 140,
            child: Text(
              matchLabel,
              style: TextStyle(color: textSecondary, fontSize: 13),
            ),
          ),
          Expanded(
            child: Tooltip(
              message: matchValue,
              waitDuration: const Duration(milliseconds: 250),
              child: Text(
                matchValue,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Align(
              alignment: Alignment.centerRight,
              child: Platform.isMacOS
                  ? MacosIconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: AppColors.clientError,
                      ),
                      onPressed: () => _deleteRule(rule.id),
                      boxConstraints: const BoxConstraints(
                        minHeight: 26,
                        minWidth: 26,
                      ),
                    )
                  : Platform.isWindows
                  ? fluent.IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: AppColors.clientError,
                      ),
                      onPressed: () => _deleteRule(rule.id),
                    )
                  : IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      color: AppColors.clientError,
                      tooltip: 'Remove rule',
                      onPressed: () => _deleteRule(rule.id),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  String _methodToString(rust_models.HttpMethod method) {
    switch (method) {
      case rust_models.HttpMethod.get_:
        return 'GET';
      case rust_models.HttpMethod.post:
        return 'POST';
      case rust_models.HttpMethod.put:
        return 'PUT';
      case rust_models.HttpMethod.delete:
        return 'DELETE';
      case rust_models.HttpMethod.patch:
        return 'PATCH';
      case rust_models.HttpMethod.head:
        return 'HEAD';
      case rust_models.HttpMethod.options:
        return 'OPTIONS';
      case rust_models.HttpMethod.connect:
        return 'CONNECT';
      case rust_models.HttpMethod.trace:
        return 'TRACE';
    }
  }
}
