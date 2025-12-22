import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/theme/app_theme.dart';
import '../core/models/http_transaction.dart';
import '../src/rust/models/breakpoint.dart';
import '../src/rust/models/transaction.dart' as rust_models;

/// Result of the breakpoint edit dialog
class BreakpointEditResult {
  /// Whether to resume the request (false = cancelled/do nothing)
  final bool shouldResume;

  /// The edits to apply (null = resume without modifications)
  final RequestEdit? edit;

  const BreakpointEditResult._({required this.shouldResume, this.edit});

  /// User cancelled the dialog - don't resume
  static const cancelled = BreakpointEditResult._(shouldResume: false);

  /// Resume with the original request (no modifications)
  static const resumeOriginal = BreakpointEditResult._(shouldResume: true);

  /// Resume with modifications
  factory BreakpointEditResult.resumeModified(RequestEdit edit) =>
      BreakpointEditResult._(shouldResume: true, edit: edit);
}

/// Dialog to edit a breakpointed request before resuming
class BreakpointEditDialog extends StatefulWidget {
  final HttpTransaction transaction;
  final bool isDark;

  const BreakpointEditDialog({
    super.key,
    required this.transaction,
    required this.isDark,
  });

  @override
  State<BreakpointEditDialog> createState() => _BreakpointEditDialogState();

  /// Show the dialog and return the result
  static Future<BreakpointEditResult?> show(
    BuildContext context,
    HttpTransaction transaction,
    bool isDark,
  ) {
    return showDialog<BreakpointEditResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          BreakpointEditDialog(transaction: transaction, isDark: isDark),
    );
  }
}

class _BreakpointEditDialogState extends State<BreakpointEditDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _pathController;
  late TextEditingController _bodyController;
  late String _selectedMethod;
  late Map<String, String> _headers;

  // For header editing
  final _headerKeyController = TextEditingController();
  final _headerValueController = TextEditingController();
  String? _editingHeaderKey;

  bool _hasChanges = false;

  static const _methods = [
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _selectedMethod = widget.transaction.method;

    // Include query in path for editing
    String fullPath = widget.transaction.path;
    if (widget.transaction.query != null &&
        widget.transaction.query!.isNotEmpty) {
      fullPath += '?${widget.transaction.query}';
    }
    _pathController = TextEditingController(text: fullPath);
    _bodyController = TextEditingController(
      text: widget.transaction.requestBody ?? '',
    );
    _headers = Map<String, String>.from(widget.transaction.requestHeaders);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pathController.dispose();
    _bodyController.dispose();
    _headerKeyController.dispose();
    _headerValueController.dispose();
    super.dispose();
  }

  void _markChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }

  RequestEdit? _buildRequestEdit() {
    // Check what changed
    String fullPath = widget.transaction.path;
    if (widget.transaction.query != null &&
        widget.transaction.query!.isNotEmpty) {
      fullPath += '?${widget.transaction.query}';
    }

    final methodChanged = _selectedMethod != widget.transaction.method;
    final pathChanged = _pathController.text != fullPath;
    final bodyChanged =
        _bodyController.text != (widget.transaction.requestBody ?? '');
    final headersChanged = !_mapsEqual(
      _headers,
      widget.transaction.requestHeaders,
    );

    if (!methodChanged && !pathChanged && !bodyChanged && !headersChanged) {
      return null; // No changes
    }

    return RequestEdit(
      method: methodChanged ? _stringToHttpMethod(_selectedMethod) : null,
      path: pathChanged ? _pathController.text : null,
      headers: headersChanged ? _headers : null,
      body: bodyChanged
          ? Uint8List.fromList(utf8.encode(_bodyController.text))
          : null,
    );
  }

  bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  rust_models.HttpMethod? _stringToHttpMethod(String method) {
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

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
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
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    return Dialog(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 700,
        height: 600,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            _buildHeader(textPrimary, textSecondary),
            const SizedBox(height: 16),

            // Request line (GET /path)
            _buildRequestLine(isDark, borderColor, textPrimary, textSecondary),
            const SizedBox(height: 16),

            // Tabs
            Container(
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                children: [
                  TabBar(
                    controller: _tabController,
                    indicatorColor: AppColors.primary,
                    labelColor: textPrimary,
                    unselectedLabelColor: textSecondary,
                    labelStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    tabs: [
                      Tab(text: 'Headers (${_headers.length})'),
                      const Tab(text: 'Body'),
                      const Tab(text: 'Preview'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildHeadersTab(
                    isDark,
                    borderColor,
                    textPrimary,
                    textSecondary,
                    textMuted,
                  ),
                  _buildBodyTab(isDark, borderColor, textPrimary, textMuted),
                  _buildPreviewTab(
                    isDark,
                    borderColor,
                    textPrimary,
                    textSecondary,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Action buttons
            _buildActionButtons(textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(Color textPrimary, Color textSecondary) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.redirect.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.edit_note,
            color: AppColors.redirect,
            size: 24,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Edit Breakpointed Request',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Modify the request before forwarding to ${widget.transaction.host}',
                style: TextStyle(color: textSecondary, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRequestLine(
    bool isDark,
    Color borderColor,
    Color textPrimary,
    Color textSecondary,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.background : AppColorsLight.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          // Method dropdown
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.getMethodColor(
                _selectedMethod,
              ).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedMethod,
                items: _methods
                    .map(
                      (method) => DropdownMenuItem(
                        value: method,
                        child: Text(
                          method,
                          style: TextStyle(
                            color: AppColors.getMethodColor(method),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedMethod = value);
                    _markChanged();
                  }
                },
                dropdownColor: isDark
                    ? AppColors.surface
                    : AppColorsLight.surface,
                style: TextStyle(
                  color: AppColors.getMethodColor(_selectedMethod),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Host (read-only)
          Text(
            '${widget.transaction.scheme}://${widget.transaction.host}${widget.transaction.portStr}',
            style: TextStyle(
              color: textSecondary,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),

          // Path input
          Expanded(
            child: TextField(
              controller: _pathController,
              style: TextStyle(
                color: textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 8,
                ),
                hintText: '/path',
                hintStyle: TextStyle(
                  color: textSecondary.withValues(alpha: 0.5),
                ),
              ),
              onChanged: (_) => _markChanged(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeadersTab(
    bool isDark,
    Color borderColor,
    Color textPrimary,
    Color textSecondary,
    Color textMuted,
  ) {
    final background = isDark
        ? AppColors.background
        : AppColorsLight.background;

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          // Add header row
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _headerKeyController,
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Header name',
                      hintStyle: TextStyle(color: textMuted, fontSize: 11),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _headerValueController,
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Header value',
                      hintStyle: TextStyle(color: textMuted, fontSize: 11),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(
                    _editingHeaderKey != null ? Icons.check : Icons.add,
                    size: 18,
                  ),
                  color: AppColors.primary,
                  tooltip: _editingHeaderKey != null
                      ? 'Update header'
                      : 'Add header',
                  onPressed: _addOrUpdateHeader,
                ),
                if (_editingHeaderKey != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: textMuted,
                    tooltip: 'Cancel edit',
                    onPressed: () {
                      setState(() {
                        _editingHeaderKey = null;
                        _headerKeyController.clear();
                        _headerValueController.clear();
                      });
                    },
                  ),
              ],
            ),
          ),

          // Headers list
          Expanded(
            child: _headers.isEmpty
                ? Center(
                    child: Text(
                      'No headers',
                      style: TextStyle(color: textMuted, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    itemCount: _headers.length,
                    itemBuilder: (context, index) {
                      final entry = _headers.entries.elementAt(index);
                      final isEditing = _editingHeaderKey == entry.key;

                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isEditing
                              ? AppColors.primary.withValues(alpha: 0.1)
                              : null,
                          border: Border(
                            bottom: BorderSide(
                              color: borderColor.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 160,
                              child: Text(
                                entry.key,
                                style: TextStyle(
                                  color: textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                entry.value,
                                style: TextStyle(
                                  color: textPrimary,
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit, size: 14),
                              color: textMuted,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 24,
                                minHeight: 24,
                              ),
                              tooltip: 'Edit header',
                              onPressed: () =>
                                  _startEditingHeader(entry.key, entry.value),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 14),
                              color: AppColors.clientError,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 24,
                                minHeight: 24,
                              ),
                              tooltip: 'Remove header',
                              onPressed: () => _removeHeader(entry.key),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _addOrUpdateHeader() {
    final key = _headerKeyController.text.trim();
    final value = _headerValueController.text;

    if (key.isEmpty) return;

    setState(() {
      // If we were editing an existing header with a different key, remove the old one
      if (_editingHeaderKey != null && _editingHeaderKey != key) {
        _headers.remove(_editingHeaderKey);
      }
      _headers[key] = value;
      _editingHeaderKey = null;
      _headerKeyController.clear();
      _headerValueController.clear();
    });
    _markChanged();
  }

  void _startEditingHeader(String key, String value) {
    setState(() {
      _editingHeaderKey = key;
      _headerKeyController.text = key;
      _headerValueController.text = value;
    });
  }

  void _removeHeader(String key) {
    setState(() {
      _headers.remove(key);
      if (_editingHeaderKey == key) {
        _editingHeaderKey = null;
        _headerKeyController.clear();
        _headerValueController.clear();
      }
    });
    _markChanged();
  }

  Widget _buildBodyTab(
    bool isDark,
    Color borderColor,
    Color textPrimary,
    Color textMuted,
  ) {
    final background = isDark
        ? AppColors.background
        : AppColorsLight.background;

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: TextField(
        controller: _bodyController,
        maxLines: null,
        expands: true,
        style: TextStyle(
          color: textPrimary,
          fontSize: 12,
          fontFamily: 'monospace',
          height: 1.4,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(12),
          hintText: 'Request body (leave empty for no body)',
          hintStyle: TextStyle(color: textMuted, fontSize: 12),
        ),
        onChanged: (_) => _markChanged(),
      ),
    );
  }

  Widget _buildPreviewTab(
    bool isDark,
    Color borderColor,
    Color textPrimary,
    Color textSecondary,
  ) {
    final background = isDark
        ? AppColors.background
        : AppColorsLight.background;

    // Build the raw request preview
    final buffer = StringBuffer();
    buffer.writeln('$_selectedMethod ${_pathController.text} HTTP/1.1');
    buffer.writeln(
      'Host: ${widget.transaction.host}${widget.transaction.portStr}',
    );

    for (final entry in _headers.entries) {
      if (entry.key.toLowerCase() != 'host') {
        buffer.writeln('${entry.key}: ${entry.value}');
      }
    }

    if (_bodyController.text.isNotEmpty) {
      buffer.writeln();
      buffer.write(_bodyController.text);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          buffer.toString(),
          style: TextStyle(
            color: textPrimary,
            fontSize: 11,
            fontFamily: 'monospace',
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(Color textMuted) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // Reset button
        if (_hasChanges)
          TextButton.icon(
            icon: const Icon(Icons.undo, size: 16),
            label: const Text('Reset'),
            style: TextButton.styleFrom(foregroundColor: textMuted),
            onPressed: _resetChanges,
          ),
        const Spacer(),

        // Cancel button
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(BreakpointEditResult.cancelled),
          style: TextButton.styleFrom(foregroundColor: textMuted),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),

        // Resume without changes
        OutlinedButton.icon(
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('Resume Original'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.success,
            side: const BorderSide(color: AppColors.success),
          ),
          onPressed: () =>
              Navigator.of(context).pop(BreakpointEditResult.resumeOriginal),
        ),
        const SizedBox(width: 8),

        // Resume with changes
        ElevatedButton.icon(
          icon: const Icon(Icons.send, size: 18),
          label: Text(_hasChanges ? 'Resume Modified' : 'Resume'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          onPressed: () {
            final edit = _buildRequestEdit();
            if (edit != null) {
              Navigator.of(
                context,
              ).pop(BreakpointEditResult.resumeModified(edit));
            } else {
              Navigator.of(context).pop(BreakpointEditResult.resumeOriginal);
            }
          },
        ),
      ],
    );
  }

  void _resetChanges() {
    String fullPath = widget.transaction.path;
    if (widget.transaction.query != null &&
        widget.transaction.query!.isNotEmpty) {
      fullPath += '?${widget.transaction.query}';
    }

    setState(() {
      _selectedMethod = widget.transaction.method;
      _pathController.text = fullPath;
      _bodyController.text = widget.transaction.requestBody ?? '';
      _headers = Map<String, String>.from(widget.transaction.requestHeaders);
      _hasChanges = false;
      _editingHeaderKey = null;
      _headerKeyController.clear();
      _headerValueController.clear();
    });
  }
}
