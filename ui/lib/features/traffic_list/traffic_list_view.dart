// ignore_for_file: use_build_context_synchronously

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_notifier.dart';
import '../../core/models/http_transaction.dart';
import '../../core/models/traffic_state.dart';
import '../../src/rust/api/proxy_api.dart' as rust_api;
import '../../src/rust/models/breakpoint.dart';
import '../../src/rust/models/transaction.dart' as rust_models;
import '../../widgets/platform_context_menu.dart';
import '../../widgets/confirmation_dialog.dart';

enum TrafficColumn { rowIndex, method, host, path, status, time, size }

const List<TrafficColumn> _columnOrder = [
  TrafficColumn.rowIndex,
  TrafficColumn.method,
  TrafficColumn.host,
  TrafficColumn.path,
  TrafficColumn.status,
  TrafficColumn.time,
  TrafficColumn.size,
];

const double _columnSeparatorHandleWidth = 12;
const double _columnDividerThickness = 1;

/// Traffic list view showing all captured requests
class TrafficListView extends StatefulWidget {
  const TrafficListView({
    super.key,
    this.verticalScrollController,
    this.mainFocusNode,
  });

  /// Optional external scroll controller for the vertical list.
  /// If provided, the scrollbar will be managed externally.
  final ScrollController? verticalScrollController;

  /// Optional focus node to request focus on after row selection.
  /// This enables keyboard shortcuts to work after clicking a row.
  final FocusNode? mainFocusNode;

  @override
  TrafficListViewState createState() => TrafficListViewState();
}

class TrafficListViewState extends State<TrafficListView> {
  final ScrollController _horizontalScrollController = ScrollController();
  ScrollController? _internalVerticalScrollController;

  /// The vertical scroll controller - either external or internal
  ScrollController get verticalScrollController =>
      widget.verticalScrollController ??
      (_internalVerticalScrollController ??= ScrollController());

  final Map<TrafficColumn, double> _columnWidths = {
    TrafficColumn.rowIndex: 56,
    TrafficColumn.method: 86,
    TrafficColumn.host: 240,
    TrafficColumn.path: 320,
    TrafficColumn.status: 80,
    TrafficColumn.time: 90,
    TrafficColumn.size: 90,
  };

  final Map<TrafficColumn, double> _minColumnWidths = {
    TrafficColumn.rowIndex: 48,
    TrafficColumn.method: 70,
    TrafficColumn.host: 160,
    TrafficColumn.path: 200,
    TrafficColumn.status: 64,
    TrafficColumn.time: 70,
    TrafficColumn.size: 70,
  };

  double get _tableWidth {
    final widths = _columnOrder.fold<double>(
      0,
      (sum, column) => sum + _columnWidths[column]!,
    );
    final separators = (_columnOrder.length - 1) * _columnSeparatorHandleWidth;
    return widths + separators;
  }

  /// Scrolls to ensure the item at the given index is visible
  void scrollToIndex(int index, int totalCount) {
    if (!verticalScrollController.hasClients) return;

    const itemHeight = 30.0; // Fixed height per item
    final viewportHeight = verticalScrollController.position.viewportDimension;
    final currentOffset = verticalScrollController.offset;
    final maxOffset = verticalScrollController.position.maxScrollExtent;

    final itemTop = index * itemHeight;
    final itemBottom = itemTop + itemHeight;

    // Check if item is above the visible area
    if (itemTop < currentOffset) {
      verticalScrollController.animateTo(
        itemTop,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
    // Check if item is below the visible area
    else if (itemBottom > currentOffset + viewportHeight) {
      final newOffset = (itemBottom - viewportHeight).clamp(0.0, maxOffset);
      verticalScrollController.animateTo(
        newOffset,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _internalVerticalScrollController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;

    return Consumer<TrafficState>(
      builder: (context, state, _) {
        final transactions = state.filteredTransactions;
        final selected = state.selectedTransaction;
        final hasSelection =
            selected != null && transactions.any((tx) => tx.id == selected.id);
        if (!hasSelection) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (transactions.isEmpty) {
              state.selectTransaction(null);
            } else {
              state.selectTransaction(transactions.first);
            }
          });
        }

        if (transactions.isEmpty) {
          return _buildEmptyState(context, isDark);
        }

        final tableWidth = _tableWidth;
        final borderColor = isDark
            ? AppColors.surfaceBorder
            : AppColorsLight.surfaceBorder;

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = tableWidth > constraints.maxWidth
                ? tableWidth
                : constraints.maxWidth;
            final showHorizontalScrollbar = tableWidth > constraints.maxWidth;
            return Scrollbar(
              controller: _horizontalScrollController,
              thumbVisibility: showHorizontalScrollbar,
              trackVisibility: showHorizontalScrollbar,
              notificationPredicate: (notification) =>
                  notification.metrics.axis == Axis.horizontal,
              child: SingleChildScrollView(
                controller: _horizontalScrollController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  child: Column(
                    children: [
                      _buildHeader(context, state, isDark, borderColor),
                      Divider(height: 1, color: borderColor),
                      Expanded(
                        // Disable default scrollbar - we have custom one in divider
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false),
                          child: ListView.builder(
                            controller: verticalScrollController,
                            itemExtent: 30.0, // Fixed height for performance
                            itemCount: transactions.length,
                            itemBuilder: (context, index) {
                              final tx = transactions[index];
                              final isItemSelected = state
                                  .isTransactionSelected(tx.id);
                              final requestNumber = state.requestNumberFor(tx);
                              return _TrafficListItem(
                                transaction: tx,
                                isSelected: isItemSelected,
                                displayNumber: requestNumber > 0
                                    ? requestNumber
                                    : index + 1,
                                index: index,
                                onTap: () {
                                  // Handle multi-select with modifier keys
                                  final isShift =
                                      HardwareKeyboard.instance.isShiftPressed;
                                  final isMeta =
                                      HardwareKeyboard.instance.isMetaPressed;
                                  final isControl = HardwareKeyboard
                                      .instance
                                      .isControlPressed;
                                  final isModifier = Platform.isMacOS
                                      ? isMeta
                                      : isControl;

                                  if (isShift) {
                                    // Range select
                                    state.selectRange(index);
                                  } else if (isModifier) {
                                    // Toggle select
                                    state.toggleSelection(tx);
                                  } else {
                                    // Single select
                                    state.selectTransaction(tx);
                                  }
                                  // Restore focus to main focus node so keyboard shortcuts work
                                  if (widget.mainFocusNode != null) {
                                    widget.mainFocusNode!.requestFocus();
                                  } else {
                                    FocusScope.of(context).unfocus();
                                    FocusScope.of(context).requestFocus();
                                  }
                                },
                                isDark: isDark,
                                columnWidths: _columnWidths,
                                separatorColor: borderColor.withValues(
                                  alpha: 0.6,
                                ),
                                rowWidth: width - 3, // Account for left border
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.wifi_tethering,
            size: 64,
            color: textMuted.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No traffic captured yet',
            style: TextStyle(color: textSecondary, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Configure your app to use the proxy at 127.0.0.1:9090',
            style: TextStyle(color: textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    TrafficState state,
    bool isDark,
    Color borderColor,
  ) {
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;
    final separatorColor = borderColor.withValues(alpha: 0.7);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      color: surface,
      child: Row(
        children: [
          for (int i = 0; i < _columnOrder.length; i++) ...[
            _buildHeaderCell(
              column: _columnOrder[i],
              width: _columnWidths[_columnOrder[i]]!,
              labelColor: textMuted,
              state: state,
            ),
            if (i < _columnOrder.length - 1)
              _buildColumnSeparator(
                color: separatorColor,
                column: _columnOrder[i],
                next: _columnOrder[i + 1],
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeaderCell({
    required TrafficColumn column,
    required double width,
    required Color labelColor,
    required TrafficState state,
  }) {
    final sortField = _sortFieldForColumn(column);
    final isSorted = state.sortField == sortField;
    final isRightAligned =
        column == TrafficColumn.time || column == TrafficColumn.size;
    final isCenter =
        column == TrafficColumn.status || column == TrafficColumn.rowIndex;

    return SizedBox(
      width: width,
      child: InkWell(
        onTap: () => state.setSortField(sortField),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                _labelForColumn(column),
                style: TextStyle(
                  color: labelColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: isRightAligned
                    ? TextAlign.right
                    : (isCenter ? TextAlign.center : TextAlign.left),
              ),
            ),
            if (isSorted)
              Icon(
                state.sortAscending
                    ? Icons.arrow_drop_up
                    : Icons.arrow_drop_down,
                size: 16,
                color: AppColors.primary,
              ),
            if (!isSorted) const SizedBox(width: 16), // maintain spacing
          ],
        ),
      ),
    );
  }

  Widget _buildColumnSeparator({
    required Color color,
    required TrafficColumn column,
    required TrafficColumn next,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (details) =>
          _resizeColumns(column, next, details.delta.dx),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: SizedBox(
          width: _columnSeparatorHandleWidth,
          height: 26,
          child: Center(
            child: Container(
              width: _columnDividerThickness,
              height: double.infinity,
              color: color,
            ),
          ),
        ),
      ),
    );
  }

  void _resizeColumns(TrafficColumn column, TrafficColumn next, double delta) {
    final currentWidth = _columnWidths[column]!;
    final nextWidth = _columnWidths[next]!;
    final minCurrent = _minColumnWidths[column]!;
    final minNext = _minColumnWidths[next]!;

    double newCurrent = (currentWidth + delta).clamp(
      minCurrent,
      double.maxFinite,
    );
    double appliedDelta = newCurrent - currentWidth;

    double newNext = (nextWidth - appliedDelta).clamp(
      minNext,
      double.maxFinite,
    );
    double nextDelta = nextWidth - newNext;

    if (nextDelta != appliedDelta) {
      newCurrent = currentWidth + nextDelta;
      appliedDelta = nextDelta;
      newNext = nextWidth - nextDelta;
    }

    if (appliedDelta == 0) {
      return;
    }

    setState(() {
      _columnWidths[column] = newCurrent;
      _columnWidths[next] = newNext;
    });
  }

  String _labelForColumn(TrafficColumn column) {
    switch (column) {
      case TrafficColumn.rowIndex:
        return '#';
      case TrafficColumn.method:
        return 'Method';
      case TrafficColumn.host:
        return 'Host';
      case TrafficColumn.path:
        return 'Path';
      case TrafficColumn.status:
        return 'Status';
      case TrafficColumn.time:
        return 'Time';
      case TrafficColumn.size:
        return 'Size';
    }
  }

  TrafficSortField _sortFieldForColumn(TrafficColumn column) {
    switch (column) {
      case TrafficColumn.rowIndex:
        return TrafficSortField.requestNumber;
      case TrafficColumn.method:
        return TrafficSortField.method;
      case TrafficColumn.host:
        return TrafficSortField.host;
      case TrafficColumn.path:
        return TrafficSortField.path;
      case TrafficColumn.status:
        return TrafficSortField.status;
      case TrafficColumn.time:
        return TrafficSortField.duration;
      case TrafficColumn.size:
        return TrafficSortField.size;
    }
  }
}

/// Single traffic list item
class _TrafficListItem extends StatelessWidget {
  final HttpTransaction transaction;
  final bool isSelected;
  final int displayNumber;
  final int index; // Index for range selection
  final VoidCallback onTap;
  final bool isDark;
  final Map<TrafficColumn, double> columnWidths;
  final Color separatorColor;
  final double rowWidth;

  const _TrafficListItem({
    required this.transaction,
    required this.isSelected,
    required this.displayNumber,
    required this.index,
    required this.onTap,
    required this.isDark,
    required this.columnWidths,
    required this.separatorColor,
    required this.rowWidth,
  });

  @override
  Widget build(BuildContext context) {
    final isBreakpointed = transaction.state == TransactionState.breakpointed;
    final surfaceLight = isDark
        ? AppColors.surfaceLight
        : AppColorsLight.surfaceLight;
    final surfaceBorder = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;
    // Alternating row colors for better readability
    final isOddRow = displayNumber % 2 == 1;
    final rowBackground = isOddRow
        ? (isDark
              ? AppColors.surfaceLight.withValues(alpha: 0.3)
              : AppColorsLight.surfaceLight)
        : Colors.transparent;

    return Material(
      color: isSelected
          ? AppColors.primary.withValues(alpha: 0.25)
          : isBreakpointed
          ? AppColors.redirect.withValues(alpha: 0.1)
          : rowBackground,
      child: InkWell(
        mouseCursor:
            SystemMouseCursors.basic, // Native Windows feel (arrow, not hand)
        onTap: onTap,
        onSecondaryTapUp: (details) =>
            _showContextMenu(context, details.globalPosition),
        hoverColor: surfaceLight.withValues(alpha: 0.5),
        splashColor: Colors.transparent, // No ripple on Windows
        highlightColor: Colors.transparent, // No highlight flash
        child: Container(
          height: 30.0, // Match itemExtent
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: surfaceBorder.withValues(alpha: 0.5),
                width: 1,
              ),
              left: BorderSide(
                color: isSelected ? AppColors.primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          clipBehavior: Clip.hardEdge,
          child: Row(
            children: [
              _buildCell(
                column: TrafficColumn.rowIndex,
                child: isBreakpointed
                    ? const Icon(
                        Icons.pause_circle_filled,
                        color: AppColors.redirect,
                        size: 18,
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '$displayNumber',
                          style: TextStyle(
                            color: textMuted,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
              ),
              _buildRowDivider(),
              _buildCell(
                column: TrafficColumn.method,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _MethodBadge(
                    method: transaction.method,
                    isWebsocket: transaction.isWebsocket,
                  ),
                ),
              ),
              _buildRowDivider(),
              _buildCell(
                column: TrafficColumn.host,
                child: Text(
                  transaction.host,
                  style: TextStyle(color: textSecondary, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _buildRowDivider(),
              Flexible(
                child: _buildCell(
                  column: TrafficColumn.path,
                  child: Text(
                    transaction.path,
                    style: TextStyle(color: textPrimary, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              _buildRowDivider(),
              _buildCell(
                column: TrafficColumn.status,
                child: isBreakpointed
                    ? const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Paused',
                          style: TextStyle(
                            color: AppColors.redirect,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: _StatusBadge(
                          statusCode: transaction.statusCode,
                          isDark: isDark,
                        ),
                      ),
              ),
              _buildRowDivider(),
              _buildCell(
                column: TrafficColumn.time,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    transaction.durationStr,
                    style: TextStyle(
                      color: textSecondary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
              _buildRowDivider(),
              _buildCell(
                column: TrafficColumn.size,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    transaction.sizeStr,
                    style: TextStyle(
                      color: textSecondary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCell({required TrafficColumn column, required Widget child}) {
    return SizedBox(
      width: columnWidths[column]!,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: child,
      ),
    );
  }

  Widget _buildRowDivider() {
    return SizedBox(
      width: _columnSeparatorHandleWidth,
      child: Center(
        child: Container(
          width: _columnDividerThickness,
          margin: const EdgeInsets.symmetric(vertical: 4),
          color: separatorColor.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final entries = _contextMenuEntries(context);
    final menuBackground = AppColors.surface;
    final menuBorder = AppColors.surfaceBorder;
    final menuHighlight = AppColors.primary.withValues(
      alpha: isDark ? 0.22 : 0.18,
    );
    final menuText = AppColors.textPrimary;
    final menuShortcut = AppColors.textSecondary;

    final value = await showPlatformContextMenu<String>(
      context: context,
      position: position,
      entries: entries,
      minWidth: 240, // Wider for long labels like "Breakpoint requests to..."
      macMenuWidth: 260,
      backgroundColor: menuBackground,
      borderColor: menuBorder,
      highlightColor: menuHighlight,
      textColor: menuText,
      shortcutColor: menuShortcut,
    );

    if (value != null) {
      _handleContextMenuSelection(context, value);
    }
  }

  List<PlatformContextMenuEntry<String>> _contextMenuEntries(
    BuildContext context,
  ) {
    final state = context.read<TrafficState>();
    final selectedCount = state.selectedCount;
    final isMultiSelect = selectedCount > 1;
    final deleteLabel = isMultiSelect
        ? 'Delete $selectedCount requests'
        : 'Delete request';

    // When multiple items are selected, show a simplified menu
    if (isMultiSelect) {
      final exportLabel = 'Export $selectedCount requests (.har)';
      return [
        PlatformContextMenuItem<String>(
          value: 'export_selected',
          label: exportLabel,
        ),
        const PlatformContextMenuDivider<String>(),
        PlatformContextMenuItem<String>(value: 'delete', label: deleteLabel),
      ];
    }

    // Single selection - show full menu
    return [
      const PlatformContextMenuItem<String>(
        value: 'breakpoint_host',
        label: 'Breakpoint requests to this host',
      ),
      const PlatformContextMenuItem<String>(
        value: 'breakpoint_url',
        label: 'Breakpoint requests to this URL',
      ),
      const PlatformContextMenuItem<String>(
        value: 'breakpoint_exact',
        label: 'Breakpoint this exact request',
      ),
      const PlatformContextMenuDivider<String>(),
      const PlatformContextMenuItem<String>(
        value: 'replay',
        label: 'Replay Request',
      ),
      const PlatformContextMenuItem<String>(
        value: 'copy_curl',
        label: 'Copy as cURL',
      ),
      const PlatformContextMenuItem<String>(
        value: 'export_selected',
        label: 'Export request (.har)',
      ),
      const PlatformContextMenuDivider<String>(),
      PlatformContextMenuItem<String>(value: 'delete', label: deleteLabel),
    ];
  }

  Future<void> _handleContextMenuSelection(
    BuildContext context,
    String value,
  ) async {
    final tx = transaction;
    switch (value) {
      case 'breakpoint_host':
        _addBreakpointRule(
          context,
          hostContains: tx.host,
          description: 'Breakpoint added for ${tx.host}',
        );
        break;
      case 'breakpoint_url':
        _addBreakpointRule(
          context,
          hostContains: tx.host,
          pathContains: tx.path,
          description: 'Breakpoint added for ${tx.host}${tx.shortPath}',
        );
        break;
      case 'breakpoint_exact':
        _addBreakpointRule(
          context,
          method: _methodFromString(tx.method),
          hostContains: tx.host,
          pathContains: tx.path,
          description: 'Breakpoint added for ${tx.method} ${tx.host}${tx.path}',
        );
        break;
      case 'replay':
        _replayRequest(context);
        break;
      case 'copy_curl':
        _copyAsCurl(context);
        break;
      case 'delete':
        await _deleteSelected(context);
        break;
      case 'export_selected':
        await _exportSelected(context);
        break;
    }
  }

  Future<void> _deleteSelected(BuildContext context) async {
    final state = context.read<TrafficState>();
    final count = state.selectedCount;
    if (count == 0) return;

    final message = count == 1
        ? 'Are you sure you want to delete this request?'
        : 'Are you sure you want to delete $count requests?';

    final confirmed = await showDeleteConfirmation(
      context: context,
      message: message,
    );

    if (!confirmed) return;

    state.deleteSelected();
  }

  Future<void> _exportSelected(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final state = context.read<TrafficState>();
    final count = state.selectedCount;
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final suggestedName = 'cheddar_selected_${count}_$timestamp.har';

    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Selected Requests',
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

      final exported = await state.exportSelectedHarToPath(outputPath: path);
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Exported $exported requests')),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  void _addBreakpointRule(
    BuildContext context, {
    rust_models.HttpMethod? method,
    String? hostContains,
    String? pathContains,
    required String description,
  }) {
    if (_breakpointRuleExists(
      method: method,
      hostContains: hostContains,
      pathContains: pathContains,
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Breakpoint already exists for this target'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    try {
      rust_api.addBreakpointRule(
        input: BreakpointRuleInput(
          enabled: true,
          method: method,
          hostContains: hostContains,
          pathContains: pathContains,
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(description),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error adding breakpoint: $e'),
          backgroundColor: AppColors.serverError,
        ),
      );
    }
  }

  bool _breakpointRuleExists({
    rust_models.HttpMethod? method,
    String? hostContains,
    String? pathContains,
  }) {
    final existing = rust_api.listBreakpointRules();
    return existing.any((rule) {
      final sameMethod = rule.method == method;
      final sameHost = (rule.hostContains ?? '') == (hostContains ?? '');
      final samePath = (rule.pathContains ?? '') == (pathContains ?? '');
      return sameMethod && sameHost && samePath;
    });
  }

  Future<void> _replayRequest(BuildContext context) async {
    try {
      final result = await rust_api.replayRequest(
        transactionId: transaction.id,
      );
      if (context.mounted) {
        if (result.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Request replayed (status: ${result.statusCode ?? 'pending'})',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Replay failed: ${result.error ?? 'Unknown error'}',
              ),
              backgroundColor: AppColors.serverError,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppColors.serverError,
          ),
        );
      }
    }
  }

  void _copyAsCurl(BuildContext context) {
    final tx = transaction;
    final scheme = tx.scheme;
    final host = tx.host;
    final port = tx.port;
    final path = tx.path;
    final method = tx.method;

    // Build the URL
    String url;
    if ((scheme == 'https' && port == 443) ||
        (scheme == 'http' && port == 80)) {
      url = '$scheme://$host$path';
    } else {
      url = '$scheme://$host:$port$path';
    }

    // Build curl command
    final buffer = StringBuffer();
    buffer.write("curl -X $method '$url'");

    // Add headers
    tx.requestHeaders.forEach((key, value) {
      if (key.toLowerCase() != 'host' &&
          key.toLowerCase() != 'content-length') {
        buffer.write(" \\\n  -H '$key: $value'");
      }
    });

    // Add body if present
    if (tx.requestBody != null && tx.requestBody!.isNotEmpty) {
      final bodyStr = tx.requestBody!;
      // Escape single quotes in body
      final escapedBody = bodyStr.replaceAll("'", "'\\''");
      buffer.write(" \\\n  -d '$escapedBody'");
    }

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied as cURL'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  rust_models.HttpMethod? _methodFromString(String method) {
    switch (method.toUpperCase()) {
      case 'GET':
        return rust_models.HttpMethod.get_;
      case 'POST':
        return rust_models.HttpMethod.post;
      case 'PUT':
        return rust_models.HttpMethod.put;
      case 'PATCH':
        return rust_models.HttpMethod.patch;
      case 'DELETE':
        return rust_models.HttpMethod.delete;
      case 'HEAD':
        return rust_models.HttpMethod.head;
      case 'OPTIONS':
        return rust_models.HttpMethod.options;
      case 'CONNECT':
        return rust_models.HttpMethod.connect;
      case 'TRACE':
        return rust_models.HttpMethod.trace;
      default:
        return null;
    }
  }
}

/// HTTP method badge with color
class _MethodBadge extends StatelessWidget {
  final String method;
  final bool isWebsocket;

  const _MethodBadge({required this.method, this.isWebsocket = false});

  @override
  Widget build(BuildContext context) {
    final color = AppColors.getMethodColor(method);
    final wsColor = AppColors.methodPatch; // Purple for WebSocket

    if (isWebsocket) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: wsColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              'WS',
              style: TextStyle(
                color: wsColor,
                fontSize: 8,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            method,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      );
    }

    return Text(
      method,
      style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        fontFamily: 'monospace',
      ),
    );
  }
}

/// HTTP status code badge with color
class _StatusBadge extends StatelessWidget {
  final int? statusCode;
  final bool isDark;

  const _StatusBadge({this.statusCode, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    if (statusCode == null) {
      return Text('-', style: TextStyle(color: textMuted, fontSize: 11));
    }

    final color = AppColors.getStatusColor(statusCode!);
    return Text(
      '$statusCode',
      style: TextStyle(
        color: color,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        fontFamily: 'monospace',
      ),
    );
  }
}
