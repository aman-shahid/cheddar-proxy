import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models/http_transaction.dart';
import '../../core/models/traffic_state.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_notifier.dart';
import '../../core/widgets/body_viewer.dart';
import '../../core/widgets/headers_viewer.dart';
import '../../src/rust/api/proxy_api.dart' as rust_api;
import 'composer_state.dart';

/// Request Composer Panel - Raw request editor with resizable sections
class ComposerPanel extends StatefulWidget {
  const ComposerPanel({super.key});

  @override
  State<ComposerPanel> createState() => _ComposerPanelState();
}

class _ComposerPanelState extends State<ComposerPanel> {
  late TextEditingController _urlController;
  late TextEditingController _headersController;
  late TextEditingController _bodyController;
  late FocusNode _urlFocusNode;

  // Section heights (absolute pixels)
  double _headersHeight = 120;
  double _bodyHeight = 150;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _headersController = TextEditingController();
    _bodyController = TextEditingController();
    _urlFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _headersController.dispose();
    _bodyController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final trafficState = context.watch<TrafficState>();
    final isDark = themeNotifier.isDarkMode;

    return Consumer<ComposerState>(
      builder: (context, state, _) {
        // Sync controllers with state
        if (_urlController.text != state.url) {
          _urlController.text = state.url;
        }
        final rawHeaders = _buildRawHeadersText(state);
        if (_headersController.text.isEmpty && rawHeaders.isNotEmpty) {
          _headersController.text = rawHeaders;
        }
        if (_bodyController.text.isEmpty && state.body.isNotEmpty) {
          _bodyController.text = state.body;
        }

        final surfaceLight = isDark
            ? AppColors.surfaceLight
            : AppColorsLight.surfaceLight;
        final borderColor = isDark
            ? AppColors.surfaceBorder
            : AppColorsLight.surfaceBorder;

        return Container(
          color: surfaceLight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Fixed header bar
              _buildHeader(context, state, isDark),
              Divider(height: 1, color: borderColor),
              // Fixed URL bar
              _buildUrlBar(context, state, isDark),
              Divider(height: 1, color: borderColor),
              // Fixed import actions
              _buildImportActions(context, state, trafficState, isDark),
              Divider(height: 1, color: borderColor),
              // Scrollable content area with resizable sections
              Expanded(
                child: SingleChildScrollView(
                  child: _buildResizableContent(context, state, isDark),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildResizableContent(
    BuildContext context,
    ComposerState state,
    bool isDark,
  ) {
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final hasResponse = state.response != null;
    // Show body if method supports it (POST/PUT/etc) OR if there's actual content to show
    // This handles cases like GET requests with bodies (rare but possible) or preserving data when switching methods
    final showBody = state.methodSupportsBody || state.body.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Headers section (resizable)
        SizedBox(
          height: _headersHeight,
          child: _buildHeadersSection(context, state, isDark),
        ),
        // Body section (only for POST/PUT/PATCH)
        if (showBody) ...[
          // Headers-Body resize handle
          _buildResizeHandle(
            borderColor: borderColor,
            onDrag: (delta) {
              setState(() {
                _headersHeight = (_headersHeight + delta).clamp(60.0, 400.0);
              });
            },
          ),
          // Body section (resizable)
          SizedBox(
            height: _bodyHeight,
            child: _buildBodySection(context, state, isDark),
          ),
        ],
        // Response section (if any)
        if (hasResponse) ...[
          // Resize handle between last section and response
          _buildResizeHandle(
            borderColor: borderColor,
            onDrag: (delta) {
              setState(() {
                if (showBody) {
                  _bodyHeight = (_bodyHeight + delta).clamp(60.0, 400.0);
                } else {
                  _headersHeight = (_headersHeight + delta).clamp(60.0, 400.0);
                }
              });
            },
          ),
          // Response section (auto-height based on content, min 200)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 200),
            child: _buildResponseSection(context, state, isDark),
          ),
        ],
      ],
    );
  }

  Widget _buildResizeHandle({
    required Color borderColor,
    required Function(double) onDrag,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        child: Container(
          height: 5,
          color: borderColor.withValues(alpha: 0.2),
          child: Center(
            child: Container(
              width: 32,
              height: 1,
              color: borderColor.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }

  String _buildRawHeadersText(ComposerState state) {
    return state.headers
        .where((h) => h.enabled && h.key.isNotEmpty)
        .map((h) => '${h.key}: ${h.value}')
        .join('\n');
  }

  void _parseRawHeaders(String rawText, ComposerState state) {
    final lines = rawText.split('\n');
    final newHeaders = <HeaderEntry>[];
    for (final line in lines) {
      final colonIndex = line.indexOf(':');
      if (colonIndex > 0) {
        final key = line.substring(0, colonIndex).trim();
        final value = line.substring(colonIndex + 1).trim();
        if (key.isNotEmpty) {
          newHeaders.add(HeaderEntry(key: key, value: value, enabled: true));
        }
      } else if (line.trim().isNotEmpty) {
        newHeaders.add(HeaderEntry(key: line.trim(), value: '', enabled: true));
      }
    }
    state.setRawHeaders(newHeaders);
  }

  Widget _buildHeader(BuildContext context, ComposerState state, bool isDark) {
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: surface,
      child: Row(
        children: [
          Icon(Icons.send_outlined, size: 14, color: AppColors.primary),
          const SizedBox(width: 8),
          Text(
            'Composer',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: textPrimary,
            ),
          ),
          if (state.sourceTransactionId != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'from ${state.sourceTransactionId!.substring(0, 8)}',
                style: const TextStyle(fontSize: 10, color: AppColors.primary),
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            icon: Icon(Icons.clear_all, size: 14, color: textMuted),
            tooltip: 'Clear',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () {
              state.clear();
              _headersController.clear();
              _bodyController.clear();
              _urlController.clear();
            },
          ),
          IconButton(
            icon: Icon(Icons.close, size: 14, color: textMuted),
            tooltip: 'Close',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => state.close(),
          ),
        ],
      ),
    );
  }

  Widget _buildUrlBar(BuildContext context, ComposerState state, bool isDark) {
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    return Container(
      height: 32,
      color: surface,
      child: Row(
        children: [
          // Method dropdown
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: state.method,
                isDense: true,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  color: AppColors.getMethodColor(state.method),
                ),
                dropdownColor: surface,
                icon: Icon(
                  Icons.arrow_drop_down,
                  size: 14,
                  color: AppColors.getMethodColor(state.method),
                ),
                items: const [
                  DropdownMenuItem(value: 'GET', child: Text('GET')),
                  DropdownMenuItem(value: 'POST', child: Text('POST')),
                  DropdownMenuItem(value: 'PUT', child: Text('PUT')),
                  DropdownMenuItem(value: 'PATCH', child: Text('PATCH')),
                  DropdownMenuItem(value: 'DELETE', child: Text('DELETE')),
                  DropdownMenuItem(value: 'HEAD', child: Text('HEAD')),
                  DropdownMenuItem(value: 'OPTIONS', child: Text('OPTIONS')),
                ],
                onChanged: (v) => state.setMethod(v ?? 'GET'),
              ),
            ),
          ),
          // URL input
          Expanded(
            child: TextField(
              controller: _urlController,
              focusNode: _urlFocusNode,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'https://api.example.com/endpoint',
                hintStyle: TextStyle(
                  color: textMuted.withValues(alpha: 0.4),
                  fontSize: 11,
                ),
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: (v) => state.setUrl(v),
            ),
          ),
          // Send button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              height: 24,
              child: ElevatedButton(
                onPressed: state.isSending
                    ? null
                    : () => _sendRequest(context, state),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    // macOS uses slight rounding, Windows is flat
                    borderRadius: BorderRadius.circular(
                      Platform.isMacOS ? 4 : 2,
                    ),
                  ),
                  elevation: 0,
                ),
                child: state.isSending
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Colors.black,
                        ),
                      )
                    : const Text(
                        'Send',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportActions(
    BuildContext context,
    ComposerState state,
    TrafficState trafficState,
    bool isDark,
  ) {
    final hasSelection = trafficState.selectedTransaction != null;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          InkWell(
            onTap: hasSelection
                ? () => _importSelected(context, state, trafficState)
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.download,
                  size: 12,
                  color: hasSelection
                      ? textSecondary
                      : textSecondary.withValues(alpha: 0.3),
                ),
                const SizedBox(width: 6),
                Text(
                  'Import Selected',
                  style: TextStyle(
                    fontSize: 11,
                    color: hasSelection
                        ? textSecondary
                        : textSecondary.withValues(alpha: 0.3),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          InkWell(
            onTap: () => _pasteCurl(context, state),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.content_paste, size: 12, color: textSecondary),
                const SizedBox(width: 6),
                Text(
                  'Paste cURL',
                  style: TextStyle(fontSize: 11, color: textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importSelected(
    BuildContext context,
    ComposerState state,
    TrafficState trafficState,
  ) async {
    final selectedTx = trafficState.selectedTransaction;
    if (selectedTx == null) return;

    try {
      final fullRustTx = await rust_api.fetchTransaction(id: selectedTx.id);
      final fullTx = HttpTransaction.fromRust(fullRustTx);
      state.importFromTransaction(fullTx);
      _urlController.text = state.url;
      _headersController.text = _buildRawHeadersText(state);
      _bodyController.text = state.body;
      if (mounted) setState(() {});
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to import: $e')));
      }
    }
  }

  Widget _buildHeadersSection(
    BuildContext context,
    ComposerState state,
    bool isDark,
  ) {
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final surfaceLight = isDark
        ? AppColors.surfaceLight
        : AppColorsLight.surfaceLight;

    // Count valid headers (non-empty keys)
    final headerCount = state.headers
        .where((h) => h.key.isNotEmpty && h.enabled)
        .length;

    return Container(
      color: surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text(
                  'Headers',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                  ),
                ),
                if (headerCount > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: surfaceLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$headerCount',
                      style: TextStyle(color: textSecondary, fontSize: 10),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _headersController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.4,
                  color: textPrimary,
                ),
                decoration: InputDecoration(
                  hintText:
                      'Content-Type: application/json\nAuthorization: Bearer token',
                  hintStyle: TextStyle(
                    color: textMuted.withValues(alpha: 0.4),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.only(bottom: 8),
                ),
                onChanged: (v) => _parseRawHeaders(v, state),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBodySection(
    BuildContext context,
    ComposerState state,
    bool isDark,
  ) {
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    return Container(
      color: surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              'Body',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _bodyController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.4,
                  color: textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: '{\n  "key": "value"\n}',
                  hintStyle: TextStyle(
                    color: textMuted.withValues(alpha: 0.4),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.only(bottom: 8),
                ),
                onChanged: (v) => state.setBody(v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResponseSection(
    BuildContext context,
    ComposerState state,
    bool isDark,
  ) {
    final response = state.response!;
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    final statusColor = response.error != null
        ? AppColors.serverError
        : response.statusCode != null
        ? AppColors.getStatusColor(response.statusCode!)
        : textSecondary;

    // Error case
    if (response.error != null) {
      return Container(
        color: surface,
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Response',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    response.error!,
                    style: TextStyle(
                      color: AppColors.serverError,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Request failed',
              style: TextStyle(color: AppColors.serverError, fontSize: 11),
            ),
          ],
        ),
      );
    }

    // Success case - show headers and body like Response tab
    return Container(
      color: surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status bar
            Row(
              children: [
                Text(
                  'Response',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${response.statusCode} ${response.statusMessage ?? ''}',
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${response.duration.inMilliseconds}ms',
                  style: TextStyle(color: textSecondary, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Headers section
            SectionHeader(
              title: 'Headers',
              count: response.headers.length,
              isDark: isDark,
            ),
            const SizedBox(height: 8),
            HeadersViewer(
              headers: response.headers,
              isDark: isDark,
              compact: true,
            ),
            // Body section
            if ((response.body != null && response.body!.isNotEmpty) ||
                (response.bodyBytes != null &&
                    response.bodyBytes!.isNotEmpty)) ...[
              const SizedBox(height: 16),
              SectionHeader(
                title: 'Body',
                subtitle: response.contentType,
                isDark: isDark,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 250,
                child: BodyViewer(
                  bodyText: response.body,
                  bodyBytes: response.bodyBytes,
                  contentType: response.contentType,
                  isDark: isDark,
                  compact: true,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _sendRequest(BuildContext context, ComposerState state) async {
    if (state.url.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter a URL')));
      return;
    }

    _parseRawHeaders(_headersController.text, state);
    state.setBody(_bodyController.text);
    state.setSending(true);
    final stopwatch = Stopwatch()..start();

    try {
      rust_api.ReplayResult result;

      if (state.sourceTransactionId != null) {
        result = await rust_api.replayRequest(
          transactionId: state.sourceTransactionId!,
          methodOverride: state.method,
          pathOverride: Uri.parse(state.url).path,
          headersOverride: state.buildHeadersMap(),
          bodyOverride: state.buildBodyBytes(),
        );
      } else {
        result = await rust_api.sendDirectRequest(
          url: state.url,
          method: state.method,
          headers: state.buildHeadersMap(),
          body: state.buildBodyBytes(),
        );
      }

      stopwatch.stop();

      if (result.success) {
        String? responseBody;
        Uint8List? responseBodyBytes;
        String? responseContentType;
        Map<String, String>? responseHeaders;

        // Small delay to ensure storage has persisted the transaction
        await Future.delayed(const Duration(milliseconds: 100));

        try {
          final fullTx = await rust_api.fetchTransaction(
            id: result.transactionId,
          );
          final tx = HttpTransaction.fromRust(fullTx);
          responseBody = tx.responseBody;
          responseBodyBytes = tx.responseBodyBytes;
          responseContentType = tx.responseContentType;
          responseHeaders = tx.responseHeaders;
        } catch (e) {
          // Log error but continue - we still have status code
          debugPrint('Failed to fetch transaction body: $e');
        }

        state.setResponse(
          ComposerResponse(
            statusCode: result.statusCode,
            statusMessage: result.statusCode != null ? 'OK' : null,
            headers: responseHeaders ?? {},
            body: responseBody,
            bodyBytes: responseBodyBytes,
            contentType: responseContentType,
            duration: stopwatch.elapsed,
          ),
        );
      } else {
        state.setResponse(
          ComposerResponse(
            duration: stopwatch.elapsed,
            error: result.error ?? 'Request failed',
          ),
        );
      }
    } catch (e) {
      stopwatch.stop();
      state.setResponse(
        ComposerResponse(duration: stopwatch.elapsed, error: e.toString()),
      );
    }
  }

  Future<void> _pasteCurl(BuildContext context, ComposerState state) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      final success = state.importFromCurl(data.text!);
      if (success) {
        _headersController.text = _buildRawHeadersText(state);
        _bodyController.text = state.body;
        _urlController.text = state.url;
        setState(() {});
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not parse cURL command')),
        );
      }
    }
  }
}
