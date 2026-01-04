// ignore_for_file: use_build_context_synchronously

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_notifier.dart';
import '../../core/models/http_transaction.dart';
import '../../core/models/traffic_state.dart';
import '../../src/rust/api/proxy_api.dart' as rust_api;
import '../../src/rust/models/breakpoint.dart';
import '../../src/rust/models/websocket.dart';
import '../../widgets/breakpoint_edit_dialog.dart';

/// Detail panel showing request/response information
class RequestDetailPanel extends StatefulWidget {
  final HttpTransaction? transaction;

  const RequestDetailPanel({super.key, this.transaction});

  @override
  State<RequestDetailPanel> createState() => _RequestDetailPanelState();
}

class _RequestDetailPanelState extends State<RequestDetailPanel>
    with TickerProviderStateMixin {
  TabController? _tabController;

  int get _tabCount => (widget.transaction?.isWebsocket ?? false) ? 4 : 3;

  @override
  void initState() {
    super.initState();
    _initTabController();
    _ensureFullTransaction();
  }

  void _initTabController() {
    _tabController?.dispose();
    _tabController = TabController(length: _tabCount, vsync: this);
  }

  HttpTransaction? _fullTransaction;

  Future<void> _ensureFullTransaction() async {
    final tx = widget.transaction;
    if (tx == null) return;

    // If ID changed or we haven't fetched yet, or state changed significantly
    if (_fullTransaction?.id == tx.id &&
        _fullTransaction?.state == tx.state &&
        _fullTransaction?.responseSize == tx.responseSize) {
      return;
    }

    try {
      final rustTx = await rust_api.fetchTransaction(id: tx.id);
      if (mounted && widget.transaction?.id == tx.id) {
        setState(() {
          _fullTransaction = HttpTransaction.fromRust(rustTx);
        });
      }
    } catch (e) {
      debugPrint('Error fetching full transaction: $e');
    }
  }

  @override
  void didUpdateWidget(RequestDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);

    final oldTx = oldWidget.transaction;
    final newTx = widget.transaction;

    // ID changed -> New request selected
    if (newTx?.id != oldTx?.id) {
      _fullTransaction = null;
      _ensureFullTransaction();
    }
    // Same ID but state/size changed
    else if (newTx != null && oldTx != null) {
      if (newTx.state != oldTx.state ||
          newTx.responseSize != oldTx.responseSize) {
        _ensureFullTransaction();
      }
    }

    final oldIsWs = oldTx?.isWebsocket ?? false;
    final newIsWs = newTx?.isWebsocket ?? false;
    if (oldIsWs != newIsWs) {
      _initTabController();
      // Force a rebuild with the new controller
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;

    if (widget.transaction == null) {
      return _buildEmptyState(isDark);
    }

    // Merge full details if available
    HttpTransaction tx = widget.transaction!;
    if (_fullTransaction != null && _fullTransaction!.id == tx.id) {
      final full = _fullTransaction!;
      tx = tx.copyWith(
        requestHeaders: full.requestHeaders,
        requestBody: full.requestBody,
        requestBodyBytes: full.requestBodyBytes,
        requestContentType: full.requestContentType,
        responseHeaders: full.responseHeaders,
        responseBody: full.responseBody,
        responseBodyBytes: full.responseBodyBytes,
        responseContentType: full.responseContentType,
        responseSize: full.responseSize ?? tx.responseSize,
        duration: full.duration ?? tx.duration,
        timing: full.timing,
        httpVersion: full.httpVersion,
        serverIp: full.serverIp,
        tlsVersion: full.tlsVersion,
        tlsCipher: full.tlsCipher,
        connectionReused: full.connectionReused,
        isWebsocket: full.isWebsocket,
      );
    }

    final isWs = tx.isWebsocket;

    // Ensure TabController matches expected tab count
    if (_tabController == null || _tabController!.length != (isWs ? 4 : 3)) {
      _initTabController();
    }

    return Column(
      children: [
        _buildHeader(tx, isDark),
        _buildTabs(isDark, isWs),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _RequestTab(transaction: tx, isDark: isDark),
              _ResponseTab(transaction: tx, isDark: isDark),
              _TimingTab(transaction: tx, isDark: isDark),
              if (isWs) _WebSocketTab(transaction: tx, isDark: isDark),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    return Consumer<TrafficState>(
      builder: (context, state, _) {
        final hasTraffic = state.transactions.isNotEmpty;

        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                hasTraffic ? Icons.touch_app_outlined : Icons.hourglass_empty,
                size: 48,
                color: textMuted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                hasTraffic
                    ? 'Select a request to inspect'
                    : 'Waiting for traffic...',
                style: TextStyle(color: textSecondary, fontSize: 14),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(HttpTransaction tx, bool isDark) {
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final background = isDark
        ? AppColors.background
        : AppColorsLight.background;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.getMethodColor(
                    tx.method,
                  ).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  tx.method,
                  style: TextStyle(
                    color: AppColors.getMethodColor(tx.method),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (tx.statusCode != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.getStatusColor(
                      tx.statusCode!,
                    ).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${tx.statusCode} ${tx.statusMessage ?? ''}',
                    style: TextStyle(
                      color: AppColors.getStatusColor(tx.statusCode!),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ] else if (tx.state == TransactionState.breakpointed) ...[
                // Actually breakpointed
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.redirect.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.pause, size: 12, color: AppColors.redirect),
                      SizedBox(width: 4),
                      Text(
                        'Breakpointed',
                        style: TextStyle(
                          color: AppColors.redirect,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // Pending/in-flight request - no response yet
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.textMuted.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Pending',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const Spacer(),
              _ActionButton(
                icon: Icons.content_copy,
                tooltip: 'Copy as cURL (⌘C)',
                onPressed: () => _copyAsCurl(tx),
                isDark: isDark,
              ),
              const SizedBox(width: 4),
              _ActionButton(
                icon: Icons.replay,
                tooltip: 'Replay request',
                onPressed: () async {
                  try {
                    final result = await rust_api.replayRequest(
                      transactionId: tx.id,
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
                },
                isDark: isDark,
              ),
              // Breakpoint action buttons only show for breakpointed transactions
              if (tx.state == TransactionState.breakpointed) ...[
                const SizedBox(width: 4),
                _BreakpointActionButtons(
                  transaction: tx,
                  compact: true,
                  iconOnly: true,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 80),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        tx.fullUrl,
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 14),
                  color: textMuted,
                  onPressed: () => _copyUrl(tx.fullUrl),
                  tooltip: 'Copy URL',
                  padding: EdgeInsets.zero,
                  alignment: Alignment.topCenter,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.access_time, size: 12, color: textMuted),
              const SizedBox(width: 6),
              SelectableText(
                tx.timestamp.toUtc().toIso8601String(),
                style: TextStyle(
                  color: textMuted,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabs(bool isDark, bool isWebsocket) {
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    return Container(
      color: surface,
      child: TabBar(
        controller: _tabController,
        indicatorColor: AppColors.primary,
        labelColor: textPrimary,
        unselectedLabelColor: textSecondary,
        labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        tabs: [
          const Tab(text: 'Request'),
          const Tab(text: 'Response'),
          const Tab(text: 'Timing'),
          if (isWebsocket) const Tab(text: 'Messages'),
        ],
      ),
    );
  }

  void _copyAsCurl(HttpTransaction tx) {
    final buffer = StringBuffer('curl');
    buffer.write(" -X ${tx.method}");
    buffer.write(" '${tx.fullUrl}'");

    for (final entry in tx.requestHeaders.entries) {
      buffer.write(" \\\n  -H '${entry.key}: ${entry.value}'");
    }

    if (tx.requestBody != null && tx.requestBody!.isNotEmpty) {
      final escapedBody = tx.requestBody!.replaceAll("'", "\\'");
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

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('URL copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}

/// Request tab content
class _RequestTab extends StatelessWidget {
  final HttpTransaction transaction;
  final bool isDark;

  const _RequestTab({required this.transaction, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: 'Headers',
            count: transaction.requestHeaders.length,
            isDark: isDark,
          ),
          const SizedBox(height: 8),
          _HeadersView(headers: transaction.requestHeaders, isDark: isDark),
          if (transaction.hasRequestBody) ...[
            const SizedBox(height: 16),
            _SectionHeader(
              title: 'Body',
              subtitle: transaction.requestContentType,
              isDark: isDark,
            ),
            const SizedBox(height: 8),
            _BodyViewer(
              bodyText: transaction.requestBody,
              bodyBytes: transaction.requestBodyBytes,
              contentType: transaction.requestContentType,
              isDark: isDark,
            ),
          ],
        ],
      ),
    );
  }
}

/// Response tab content
class _ResponseTab extends StatelessWidget {
  final HttpTransaction transaction;
  final bool isDark;

  const _ResponseTab({required this.transaction, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    if (transaction.state == TransactionState.breakpointed) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.pause_circle,
              size: 48,
              color: AppColors.redirect.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(
              'Request is paused at breakpoint',
              style: TextStyle(color: textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              transaction.host + transaction.path,
              style: TextStyle(
                color: textSecondary.withValues(alpha: 0.7),
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 16),
            const SizedBox.shrink(),
          ],
        ),
      );
    }

    if (transaction.responseHeaders == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
              color: AppColors.primary,
              strokeWidth: 2,
            ),
            const SizedBox(height: 12),
            Text(
              'Waiting for response...',
              style: TextStyle(color: textSecondary, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: 'Headers',
            count: transaction.responseHeaders?.length ?? 0,
            isDark: isDark,
          ),
          const SizedBox(height: 8),
          _HeadersView(
            headers: transaction.responseHeaders ?? {},
            isDark: isDark,
          ),
          if (transaction.hasResponseBody) ...[
            const SizedBox(height: 16),
            _SectionHeader(
              title: 'Body',
              subtitle:
                  '${transaction.sizeStr} • ${transaction.responseContentType}',
              isDark: isDark,
            ),
            const SizedBox(height: 8),
            _BodyViewer(
              bodyText: transaction.responseBody,
              bodyBytes: transaction.responseBodyBytes,
              contentType: transaction.responseContentType,
              isDark: isDark,
            ),
          ],
        ],
      ),
    );
  }
}

/// Timing tab content
class _TimingTab extends StatelessWidget {
  final HttpTransaction transaction;
  final bool isDark;

  const _TimingTab({required this.transaction, required this.isDark});

  @override
  Widget build(BuildContext context) {
    // Calculate cumulative offsets for waterfall positioning
    final totalDurationMs = transaction.duration?.inMilliseconds ?? 500;
    final dnsMs = transaction.timing.dnsLookupMs ?? 0;
    final tcpMs = transaction.timing.tcpConnectMs ?? 0;
    final tlsMs = transaction.timing.tlsHandshakeMs ?? 0;
    final reqMs = transaction.timing.requestSendMs ?? 0;
    final waitMs = transaction.timing.waitingMs ?? 0;

    // Cumulative offsets as fractions
    const dnsOffset = 0.0;
    final tcpOffset = dnsMs / totalDurationMs;
    final tlsOffset = (dnsMs + tcpMs) / totalDurationMs;
    final reqOffset = (dnsMs + tcpMs + tlsMs) / totalDurationMs;
    final waitOffset = (dnsMs + tcpMs + tlsMs + reqMs) / totalDurationMs;
    final downloadOffset =
        (dnsMs + tcpMs + tlsMs + reqMs + waitMs) / totalDurationMs;

    // Theme colors
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    // Check if detailed timing is available (replayed requests only have total_ms)
    final hasDetailedTiming =
        transaction.timing.dnsLookupMs != null ||
        transaction.timing.tcpConnectMs != null ||
        transaction.timing.tlsHandshakeMs != null ||
        transaction.timing.requestSendMs != null ||
        transaction.timing.waitingMs != null ||
        transaction.timing.contentDownloadMs != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(title: 'Timing Breakdown', isDark: isDark),
          const SizedBox(height: 12),
          if (!hasDetailedTiming) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (isDark ? Colors.amberAccent : Colors.orange).withValues(
                  alpha: 0.1,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (isDark ? Colors.amberAccent : Colors.orange)
                      .withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: isDark ? Colors.amberAccent : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Detailed timing breakdown is not available for replayed or direct requests.',
                      style: TextStyle(color: textMuted, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          _TimingBar(
            label: 'DNS Lookup',
            duration: transaction.timing.dnsLookupMs != null
                ? Duration(milliseconds: transaction.timing.dnsLookupMs!)
                : null,
            color: AppColors.methodOptions,
            maxDuration:
                transaction.duration ?? const Duration(milliseconds: 500),
            isDark: isDark,
            offsetFactor: dnsOffset,
          ),
          const SizedBox(height: 8),
          _TimingBar(
            label: 'TCP Connect',
            duration: transaction.timing.tcpConnectMs != null
                ? Duration(milliseconds: transaction.timing.tcpConnectMs!)
                : null,
            color: AppColors.methodPost,
            maxDuration:
                transaction.duration ?? const Duration(milliseconds: 500),
            isDark: isDark,
            offsetFactor: tcpOffset,
          ),
          const SizedBox(height: 8),
          _TimingBar(
            label: 'TLS Handshake',
            duration: transaction.timing.tlsHandshakeMs != null
                ? Duration(milliseconds: transaction.timing.tlsHandshakeMs!)
                : null,
            color: AppColors.methodPut,
            maxDuration:
                transaction.duration ?? const Duration(milliseconds: 500),
            isDark: isDark,
            offsetFactor: tlsOffset,
          ),
          const SizedBox(height: 8),
          _TimingBar(
            label: 'Request Sent',
            duration: transaction.timing.requestSendMs != null
                ? Duration(milliseconds: transaction.timing.requestSendMs!)
                : null,
            color: AppColors.methodGet,
            maxDuration:
                transaction.duration ?? const Duration(milliseconds: 500),
            isDark: isDark,
            offsetFactor: reqOffset,
          ),
          const SizedBox(height: 8),
          _TimingBar(
            label: 'Waiting (TTFB)',
            duration: transaction.timing.waitingMs != null
                ? Duration(milliseconds: transaction.timing.waitingMs!)
                : null,
            color: AppColors.methodPatch, // Purple - distinct from TLS (amber)
            maxDuration:
                transaction.duration ?? const Duration(milliseconds: 500),
            isDark: isDark,
            offsetFactor: waitOffset,
          ),
          const SizedBox(height: 8),
          _TimingBar(
            label: 'Content Download',
            duration: transaction.timing.contentDownloadMs != null
                ? Duration(milliseconds: transaction.timing.contentDownloadMs!)
                : null,
            color: AppColors.success,
            maxDuration:
                transaction.duration ?? const Duration(milliseconds: 500),
            isDark: isDark,
            offsetFactor: downloadOffset,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total Time',
                  style: TextStyle(
                    color: textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  transaction.durationStr,
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _SectionHeader(title: 'Connection Info', isDark: isDark),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              children: [
                _ConnectionInfoRow(
                  label: 'HTTP Version',
                  value: transaction.httpVersion,
                  isDark: isDark,
                ),
                if (transaction.serverIp != null) ...[
                  const SizedBox(height: 8),
                  _ConnectionInfoRow(
                    label: 'Server IP',
                    value: transaction.serverIp!,
                    isDark: isDark,
                  ),
                ],
                if (transaction.tlsVersion != null) ...[
                  const SizedBox(height: 8),
                  _ConnectionInfoRow(
                    label: 'TLS Version',
                    value: transaction.tlsVersion!,
                    isDark: isDark,
                  ),
                ],
                if (transaction.tlsCipher != null) ...[
                  const SizedBox(height: 8),
                  _ConnectionInfoRow(
                    label: 'TLS Cipher',
                    value: transaction.tlsCipher!,
                    isDark: isDark,
                  ),
                ],
                // Connection Reused - hidden until upstream connection pooling is implemented
                // const SizedBox(height: 8),
                // _ConnectionInfoRow(
                //   label: 'Connection Reused',
                //   value: transaction.connectionReused ? 'Yes' : 'No',
                //   isDark: isDark,
                // ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// WebSocket messages tab content
class _WebSocketTab extends StatefulWidget {
  final HttpTransaction transaction;
  final bool isDark;

  const _WebSocketTab({required this.transaction, required this.isDark});

  @override
  State<_WebSocketTab> createState() => _WebSocketTabState();
}

class _WebSocketTabState extends State<_WebSocketTab> {
  List<WebSocketMessage> _messages = [];
  bool _loading = true;
  int? _selectedIndex;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    setState(() => _loading = true);
    final messages = rust_api.getWebsocketMessages(
      connectionId: widget.transaction.id,
    );
    setState(() {
      _messages = messages;
      _loading = false;
      _selectedIndex = null;
    });
  }

  void _selectMessage(int index) {
    setState(() {
      _selectedIndex = _selectedIndex == index ? null : index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.isDark
        ? AppColors.background
        : AppColorsLight.background;
    final surface = widget.isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = widget.isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textPrimary = widget.isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = widget.isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = widget.isDark
        ? AppColors.textMuted
        : AppColorsLight.textMuted;

    if (_loading) {
      return Container(
        color: background,
        child: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    if (_messages.isEmpty) {
      return Container(
        color: background,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.chat_bubble_outline, size: 48, color: textMuted),
              const SizedBox(height: 12),
              Text(
                'No messages yet',
                style: TextStyle(color: textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _loadMessages,
                icon: Icon(Icons.refresh, size: 16, color: AppColors.primary),
                label: Text(
                  'Refresh',
                  style: TextStyle(color: AppColors.primary, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      color: background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                Text(
                  '${_messages.length} message${_messages.length == 1 ? '' : 's'}',
                  style: TextStyle(
                    color: textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.refresh, size: 16, color: textSecondary),
                  onPressed: _loadMessages,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Refresh messages',
                ),
              ],
            ),
          ),
          // Message list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isSelected = _selectedIndex == index;
                final isClientToServer =
                    msg.direction == MessageDirection.clientToServer;
                final directionColor = isClientToServer
                    ? AppColors.methodPost
                    : AppColors.success;
                final directionIcon = isClientToServer
                    ? Icons.arrow_upward
                    : Icons.arrow_downward;

                // Get opcode label
                String opcodeLabel;
                Color opcodeColor;
                switch (msg.opcode) {
                  case WebSocketOpcode.text:
                    opcodeLabel = 'TXT';
                    opcodeColor = AppColors.methodGet;
                    break;
                  case WebSocketOpcode.binary:
                    opcodeLabel = 'BIN';
                    opcodeColor = AppColors.methodPut;
                    break;
                  case WebSocketOpcode.ping:
                    opcodeLabel = 'PING';
                    opcodeColor = AppColors.methodOptions;
                    break;
                  case WebSocketOpcode.pong:
                    opcodeLabel = 'PONG';
                    opcodeColor = AppColors.methodOptions;
                    break;
                  case WebSocketOpcode.close:
                    opcodeLabel = 'CLOSE';
                    opcodeColor = AppColors.clientError;
                    break;
                  case WebSocketOpcode.continuation:
                    opcodeLabel = 'CONT';
                    opcodeColor = textMuted;
                    break;
                }

                // Get preview
                String preview;
                if (msg.opcode == WebSocketOpcode.text) {
                  try {
                    preview = utf8.decode(msg.payload);
                    if (preview.length > 100) {
                      preview = '${preview.substring(0, 100)}...';
                    }
                  } catch (_) {
                    preview = '[Binary: ${msg.payloadLength} bytes]';
                  }
                } else if (msg.opcode == WebSocketOpcode.binary) {
                  preview = '[Binary: ${msg.payloadLength} bytes]';
                } else if (msg.opcode == WebSocketOpcode.close) {
                  if (msg.payload.length >= 2) {
                    final code = (msg.payload[0] << 8) | msg.payload[1];
                    preview = 'Close code: $code';
                  } else {
                    preview = 'Close';
                  }
                } else {
                  preview = opcodeLabel;
                }

                final timestamp = DateTime.fromMillisecondsSinceEpoch(
                  msg.timestamp.toInt(),
                );
                final timeStr =
                    '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}.${timestamp.millisecond.toString().padLeft(3, '0')}';

                return GestureDetector(
                  onTap: () => _selectMessage(index),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary.withValues(alpha: 0.1)
                          : surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isSelected ? AppColors.primary : borderColor,
                        width: isSelected ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Direction indicator
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: directionColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Icon(
                            directionIcon,
                            size: 14,
                            color: directionColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Opcode badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: opcodeColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            opcodeLabel,
                            style: TextStyle(
                              color: opcodeColor,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Content preview (expands to fill available space)
                        Expanded(
                          child: Text(
                            preview,
                            style: TextStyle(
                              color: textPrimary,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Timestamp (right-aligned)
                        Text(
                          timeStr,
                          style: TextStyle(
                            color: textSecondary,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // Selected message detail panel
          if (_selectedIndex != null && _selectedIndex! < _messages.length)
            _buildSelectedMessageDetail(
              _messages[_selectedIndex!],
              surface,
              borderColor,
              textPrimary,
              textSecondary,
            ),
        ],
      ),
    );
  }

  Widget _buildSelectedMessageDetail(
    WebSocketMessage msg,
    Color surface,
    Color borderColor,
    Color textPrimary,
    Color textSecondary,
  ) {
    String fullContent;
    if (msg.opcode == WebSocketOpcode.text) {
      try {
        fullContent = utf8.decode(msg.payload);
      } catch (_) {
        fullContent = '[Unable to decode as text]';
      }
    } else if (msg.opcode == WebSocketOpcode.binary) {
      // Show hex dump for binary
      final bytes = msg.payload.take(256).toList();
      fullContent = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      if (msg.payload.length > 256) {
        fullContent += ' ... (${msg.payloadLength} bytes total)';
      }
    } else {
      fullContent = '[${msg.opcode.name} frame]';
    }

    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: surface,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with copy button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                Text(
                  'Message Content',
                  style: TextStyle(
                    color: textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${msg.payloadLength} bytes',
                  style: TextStyle(
                    color: textSecondary.withValues(alpha: 0.7),
                    fontSize: 10,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.copy, size: 14, color: textSecondary),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: fullContent));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Copied to clipboard'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Copy content',
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.close, size: 14, color: textSecondary),
                  onPressed: () => setState(() => _selectedIndex = null),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                fullContent,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Section header widget
class _SectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final String? subtitle;
  final bool isDark;

  const _SectionHeader({
    required this.title,
    this.count,
    this.subtitle,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;
    final surfaceLight = isDark
        ? AppColors.surfaceLight
        : AppColorsLight.surfaceLight;

    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            color: textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(color: textSecondary, fontSize: 11),
            ),
          ),
        ],
        if (subtitle != null) ...[
          const SizedBox(width: 8),
          Text(subtitle!, style: TextStyle(color: textMuted, fontSize: 12)),
        ],
      ],
    );
  }
}

/// Connection info row for key-value display
class _ConnectionInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;

  const _ConnectionInfoRow({
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: textSecondary, fontSize: 11)),
        Text(
          value,
          style: TextStyle(
            color: textPrimary,
            fontSize: 11,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Headers display widget
class _HeadersView extends StatelessWidget {
  final Map<String, String> headers;
  final bool isDark;

  const _HeadersView({required this.headers, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final background = isDark
        ? AppColors.background
        : AppColorsLight.surfaceLight;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final keyColor = isDark
        ? AppColorsDark.headerKey
        : AppColorsLight.headerKey;

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: headers.entries.map((entry) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: borderColor.withValues(alpha: 0.5)),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: SelectableText(
                    entry.key,
                    style: TextStyle(
                      color: keyColor,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    entry.value,
                    style: TextStyle(
                      color: textSecondary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _BreakpointActionButtons extends StatefulWidget {
  final HttpTransaction transaction;
  final bool compact;
  final bool iconOnly;

  const _BreakpointActionButtons({
    required this.transaction,
    this.compact = false,
    this.iconOnly = false,
  });

  @override
  State<_BreakpointActionButtons> createState() =>
      _BreakpointActionButtonsState();
}

class _BreakpointActionButtonsState extends State<_BreakpointActionButtons> {
  bool _isWorking = false;

  Future<void> _resume({RequestEdit? edit}) async {
    setState(() => _isWorking = true);
    try {
      await rust_api.resumeBreakpoint(
        transactionId: widget.transaction.id,
        edit: edit,
      );
      if (mounted && edit != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Request resumed with modifications'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<void> _abort() async {
    setState(() => _isWorking = true);
    try {
      rust_api.abortBreakpoint(
        transactionId: widget.transaction.id,
        reason: 'Aborted by user',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<void> _openEditDialog() async {
    final themeNotifier = context.read<ThemeNotifier>();
    final result = await BreakpointEditDialog.show(
      context,
      widget.transaction,
      themeNotifier.isDarkMode,
    );

    // Only resume if user chose to resume (not if they cancelled)
    if (mounted && result != null && result.shouldResume) {
      await _resume(edit: result.edit);
    }
  }

  @override
  Widget build(BuildContext context) {
    final buttonHeight = widget.compact ? 32.0 : null;
    final spacing = widget.compact ? 6.0 : 8.0;

    if (widget.iconOnly) {
      return Row(
        children: [
          IconButton(
            icon: const Icon(Icons.cancel_outlined, size: 18),
            tooltip: 'Abort request',
            color: AppColors.clientError,
            onPressed: _isWorking ? null : _abort,
          ),
          IconButton(
            icon: const Icon(Icons.edit_note, size: 20),
            tooltip: 'Edit & Resume',
            color: AppColors.primary,
            onPressed: _isWorking ? null : _openEditDialog,
          ),
          IconButton(
            icon: const Icon(Icons.play_arrow, size: 20),
            tooltip: 'Resume request',
            color: AppColors.success,
            onPressed: _isWorking ? null : () => _resume(),
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: widget.compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        SizedBox(
          height: buttonHeight,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.cancel_outlined, size: 16),
            label: const Text('Abort'),
            onPressed: _isWorking ? null : _abort,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.clientError,
              side: const BorderSide(color: AppColors.clientError),
              padding: widget.compact
                  ? const EdgeInsets.symmetric(horizontal: 8)
                  : null,
            ),
          ),
        ),
        SizedBox(width: spacing),
        SizedBox(
          height: buttonHeight,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.edit_note, size: 16),
            label: const Text('Edit'),
            onPressed: _isWorking ? null : _openEditDialog,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
              padding: widget.compact
                  ? const EdgeInsets.symmetric(horizontal: 8)
                  : null,
            ),
          ),
        ),
        SizedBox(width: spacing),
        SizedBox(
          height: buttonHeight,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.play_arrow, size: 16),
            label: Text(widget.compact ? 'Resume' : 'Continue'),
            onPressed: _isWorking ? null : () => _resume(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
              foregroundColor: Colors.white,
              padding: widget.compact
                  ? const EdgeInsets.symmetric(horizontal: 10)
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

enum _BodyTabType { pretty, raw, hex, image }

class _BodyTab {
  final _BodyTabType type;
  final String label;
  final String? language;

  const _BodyTab({required this.type, required this.label, this.language});
}

typedef BodyViewer = _BodyViewer;

class _BodyViewer extends StatefulWidget {
  final String? bodyText;
  final Uint8List? bodyBytes;
  final String? contentType;
  final bool isDark;

  const _BodyViewer({
    required this.bodyText,
    required this.bodyBytes,
    required this.contentType,
    required this.isDark,
  });

  @override
  State<_BodyViewer> createState() => _BodyViewerState();
}

class _BodyViewerState extends State<_BodyViewer> {
  static const maxPreviewLength = 50 * 1024; // 50KB limit for preview
  static const maxPrettyLength = 1024 * 1024; // 1MB safety cap

  late List<_BodyTab> _tabs;
  int _selectedIndex = 0;
  String? _cachedPretty;
  String? _cachedHex;

  bool get _hasBytes =>
      widget.bodyBytes != null && widget.bodyBytes!.isNotEmpty;
  bool get _hasText =>
      widget.bodyText != null && widget.bodyText!.trim().isNotEmpty;
  bool get _isPrettyTooLarge =>
      _hasText && widget.bodyText!.length > maxPrettyLength;

  @override
  void initState() {
    super.initState();
    _tabs = _buildTabs();
  }

  @override
  void didUpdateWidget(covariant _BodyViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final contentChanged =
        oldWidget.bodyText != widget.bodyText ||
        oldWidget.bodyBytes != widget.bodyBytes ||
        oldWidget.contentType != widget.contentType;
    if (contentChanged) {
      _cachedPretty = null;
      _cachedHex = null;
      final previousIndex = _selectedIndex;
      _tabs = _buildTabs();
      _selectedIndex = math.min(previousIndex, _tabs.length - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copyText = _currentCopyText;
    final surface = widget.isDark ? AppColors.surface : AppColorsLight.surface;
    final textSecondary = widget.isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final borderColor = widget.isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _panelDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Compact segmented button row
              Container(
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(_tabs.length, (index) {
                    final isSelected = _selectedIndex == index;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedIndex = index),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.primary.withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          _tabs[index].label,
                          style: TextStyle(
                            color: isSelected
                                ? AppColors.primary
                                : textSecondary,
                            fontSize: 11,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const Spacer(),
              if (copyText != null)
                IconButton(
                  icon: const Icon(Icons.copy, size: 14),
                  tooltip: 'Copy ${_tabs[_selectedIndex].label}',
                  onPressed: () => _copyToClipboard(copyText),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _buildTabContent(_tabs[_selectedIndex]),
        ],
      ),
    );
  }

  BoxDecoration get _panelDecoration => BoxDecoration(
    color: widget.isDark ? AppColors.background : AppColorsLight.surfaceLight,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(
      color: widget.isDark
          ? AppColors.surfaceBorder
          : AppColorsLight.surfaceBorder,
    ),
  );

  List<_BodyTab> _buildTabs() {
    final tabs = <_BodyTab>[];
    final prettyLang = _detectPrettyLanguage();

    if (_hasText && prettyLang != null) {
      tabs.add(
        _BodyTab(
          type: _BodyTabType.pretty,
          label: 'Pretty',
          language: prettyLang,
        ),
      );
    }
    if (_hasText) {
      tabs.add(const _BodyTab(type: _BodyTabType.raw, label: 'Raw'));
    }
    if (_hasBytes) {
      tabs.add(const _BodyTab(type: _BodyTabType.hex, label: 'Hex'));
      if (_isImageType()) {
        tabs.add(const _BodyTab(type: _BodyTabType.image, label: 'Image'));
      }
    }
    if (tabs.isEmpty) {
      tabs.add(const _BodyTab(type: _BodyTabType.raw, label: 'Raw'));
    }
    return tabs;
  }

  Widget _buildTabContent(_BodyTab tab) {
    switch (tab.type) {
      case _BodyTabType.pretty:
        return _buildPrettyView(tab);
      case _BodyTabType.raw:
        return _buildRawView();
      case _BodyTabType.hex:
        return _buildHexView();
      case _BodyTabType.image:
        return _buildImageView();
    }
  }

  Widget _buildPrettyView(_BodyTab tab) {
    final fullContent = _prettyText(tab.language);
    if (fullContent == null) {
      if (_isPrettyTooLarge) {
        return _buildLargePayloadNotice(
          'Body is larger than 1MB. Use copy or the Raw tab to open it in an external editor.',
        );
      }
      return _buildEmptyState('Unable to format body');
    }

    final isTruncated = fullContent.length > maxPreviewLength;
    final content = isTruncated
        ? fullContent.substring(0, maxPreviewLength)
        : fullContent;

    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isTruncated)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  '⚠️ Preview truncated to 50KB. Use copy to get full content.',
                  style: TextStyle(
                    color: widget.isDark ? Colors.amberAccent : Colors.orange,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            HighlightView(
              content,
              language: tab.language ?? 'json',
              theme: widget.isDark ? atomOneDarkTheme : githubTheme,
              textStyle: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRawView() {
    String? text =
        widget.bodyText ??
        (_hasBytes
            ? utf8.decode(widget.bodyBytes!, allowMalformed: true)
            : null);

    if (text == null || text.isEmpty) {
      return _buildEmptyState('Body is empty or binary');
    }

    final isTruncated = text.length > maxPreviewLength;
    if (isTruncated) {
      text = text.substring(0, maxPreviewLength);
    }

    final textColor = widget.isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isTruncated)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                '⚠️ Preview truncated to 50KB.',
                style: TextStyle(
                  color: widget.isDark ? Colors.amberAccent : Colors.orange,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          SelectableText(
            text,
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              fontFamily: 'monospace',
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHexView() {
    if (!_hasBytes) {
      return _buildEmptyState('No data available');
    }

    // Ensure we don't hex dump 5MB
    if (_cachedHex == null) {
      var bytes = widget.bodyBytes!;
      bool truncated = false;
      if (bytes.length > maxPreviewLength) {
        bytes = bytes.sublist(0, maxPreviewLength);
        truncated = true;
      }
      _cachedHex = _buildHexDump(bytes);
      if (truncated) {
        _cachedHex = "⚠️ Truncated to 50KB\n\n$_cachedHex";
      }
    }

    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        child: SelectableText(
          _cachedHex!,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildImageView() {
    if (!_hasBytes) {
      return _buildEmptyState('No image data');
    }
    return Container(
      constraints: const BoxConstraints(minHeight: 120, maxHeight: 320),
      decoration: BoxDecoration(
        color: widget.isDark ? AppColors.surface : AppColorsLight.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: widget.isDark
              ? AppColors.surfaceBorder
              : AppColorsLight.surfaceBorder,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: InteractiveViewer(
          child: Image.memory(
            widget.bodyBytes!,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Unable to render image data',
                  style: TextStyle(
                    color: widget.isDark
                        ? AppColors.textSecondary
                        : AppColorsLight.textSecondary,
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    final textMuted = widget.isDark
        ? AppColors.textMuted
        : AppColorsLight.textMuted;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Text(message, style: TextStyle(color: textMuted, fontSize: 12)),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_tabs[_selectedIndex].label} copied'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String? get _currentCopyText {
    final tab = _tabs[_selectedIndex];
    switch (tab.type) {
      case _BodyTabType.pretty:
        final pretty = _prettyText(tab.language);
        if (pretty != null) return pretty;
        return _hasText ? widget.bodyText : null;
      case _BodyTabType.raw:
        final text =
            widget.bodyText ??
            (_hasBytes
                ? utf8.decode(widget.bodyBytes!, allowMalformed: true)
                : null);
        return text?.isEmpty ?? true ? null : text;
      case _BodyTabType.hex:
        if (!_hasBytes) return null;
        _cachedHex ??= _buildHexDump(widget.bodyBytes!);
        return _cachedHex;
      case _BodyTabType.image:
        return null;
    }
  }

  String? _prettyText(String? language) {
    if (!_hasText) return null;
    if (_cachedPretty != null) return _cachedPretty;

    final text = widget.bodyText!;
    // Avoid freezing UI on large payloads
    if (text.length > maxPrettyLength) return null;

    if (language == 'json') {
      try {
        final decoded = jsonDecode(text);
        _cachedPretty = const JsonEncoder.withIndent('  ').convert(decoded);
      } catch (_) {
        _cachedPretty = text;
      }
    } else if (language == 'xml' || language == 'html') {
      _cachedPretty = text;
    } else {
      _cachedPretty = text;
    }
    return _cachedPretty;
  }

  String? _detectPrettyLanguage() {
    if (!_hasText) return null;
    final ct = (widget.contentType ?? '').toLowerCase();
    if (ct.contains('json')) return 'json';
    if (ct.contains('xml')) return 'xml';
    if (ct.contains('html')) return 'html';

    final text = widget.bodyText!.trimLeft();
    if (text.startsWith('{') || text.startsWith('[')) return 'json';
    if (text.startsWith('<')) return 'xml';
    return null;
  }

  bool _isImageType() {
    final ct = widget.contentType?.toLowerCase() ?? '';
    return ct.startsWith('image/');
  }

  String _buildHexDump(Uint8List bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length; i += 16) {
      final chunk = bytes.sublist(i, math.min(i + 16, bytes.length));
      final hex = chunk
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      final ascii = chunk.map((b) {
        final char = b;
        if (char >= 32 && char <= 126) {
          return String.fromCharCode(char);
        }
        return '.';
      }).join();
      buffer.writeln(
        '${i.toRadixString(16).padLeft(6, '0')}: ${hex.padRight(47)}  $ascii',
      );
    }
    return buffer.toString();
  }

  Widget _buildLargePayloadNotice(String message) {
    final accent = widget.isDark ? Colors.amberAccent : Colors.orange;
    final textColor = widget.isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: accent, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: textColor, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Timing bar visualization
class _TimingBar extends StatelessWidget {
  final String label;
  final Duration? duration;
  final Color color;
  final Duration maxDuration;
  final bool isDark;
  final double offsetFactor; // 0.0 to 1.0 - where the bar starts

  const _TimingBar({
    required this.label,
    required this.duration,
    required this.color,
    required this.maxDuration,
    required this.isDark,
    this.offsetFactor = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final surfaceLight = isDark
        ? AppColors.surfaceLight
        : AppColorsLight.surfaceLight;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    // Handle null duration
    if (duration == null) {
      return Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(color: textMuted, fontSize: 11),
            ),
          ),
          Expanded(
            child: Container(
              height: 20,
              decoration: BoxDecoration(
                color: surfaceLight,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: Text(
              'N/A',
              style: TextStyle(color: textMuted, fontSize: 11),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      );
    }

    final upperBound = (1.0 - offsetFactor).clamp(0.0, 1.0);
    final widthFactor = maxDuration.inMilliseconds > 0 && upperBound > 0
        ? (duration!.inMilliseconds / maxDuration.inMilliseconds).clamp(
            0.0,
            upperBound,
          )
        : 0.0;

    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: TextStyle(color: textSecondary, fontSize: 11),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = constraints.maxWidth;
              final offsetPx = totalWidth * offsetFactor;
              final barWidth = totalWidth * widthFactor;

              return Stack(
                children: [
                  // Background track
                  Container(
                    height: 20,
                    decoration: BoxDecoration(
                      color: surfaceLight,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  // Colored bar at offset position
                  Positioned(
                    left: offsetPx,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: barWidth.clamp(
                        0,
                        math.max(0.0, totalWidth - offsetPx),
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 60,
          child: Text(
            duration!.inMilliseconds == 0
                ? '<1ms'
                : '${duration!.inMilliseconds}ms',
            style: TextStyle(
              color: textSecondary,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

/// Action button widget
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isDark;

  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 16, color: textSecondary),
          ),
        ),
      ),
    );
  }
}
