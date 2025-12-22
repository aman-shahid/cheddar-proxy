import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';

import '../theme/app_theme.dart';

/// View mode for body content
enum BodyViewMode { pretty, raw, hex, image }

/// Tab definition for body viewer
class BodyViewTab {
  final BodyViewMode mode;
  final String label;
  final String? language;

  const BodyViewTab({required this.mode, required this.label, this.language});
}

/// A widget that displays HTTP body content with multiple view modes:
/// - Pretty: syntax-highlighted JSON/XML/HTML
/// - Raw: plain text
/// - Hex: hexadecimal dump
/// - Image: rendered image (if content-type is image/*)
class BodyViewer extends StatefulWidget {
  final String? bodyText;
  final Uint8List? bodyBytes;
  final String? contentType;
  final bool isDark;

  /// If true, uses a more compact style suitable for embedded use
  final bool compact;

  const BodyViewer({
    super.key,
    required this.bodyText,
    required this.bodyBytes,
    required this.contentType,
    required this.isDark,
    this.compact = false,
  });

  @override
  State<BodyViewer> createState() => _BodyViewerState();
}

class _BodyViewerState extends State<BodyViewer> {
  static const maxPreviewLength = 50 * 1024; // 50KB limit for preview
  static const maxPrettyLength = 1024 * 1024; // 1MB safety cap

  late List<BodyViewTab> _tabs;
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
  void didUpdateWidget(covariant BodyViewer oldWidget) {
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

    final padding = widget.compact ? 8.0 : 12.0;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(padding),
      decoration: widget.compact ? null : _panelDecoration,
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
          Expanded(child: _buildTabContent(_tabs[_selectedIndex])),
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

  List<BodyViewTab> _buildTabs() {
    final tabs = <BodyViewTab>[];
    final prettyLang = _detectPrettyLanguage();

    if (_hasText && prettyLang != null) {
      tabs.add(
        BodyViewTab(
          mode: BodyViewMode.pretty,
          label: 'Pretty',
          language: prettyLang,
        ),
      );
    }
    if (_hasText) {
      tabs.add(const BodyViewTab(mode: BodyViewMode.raw, label: 'Raw'));
    }
    if (_hasBytes) {
      tabs.add(const BodyViewTab(mode: BodyViewMode.hex, label: 'Hex'));
      if (_isImageType()) {
        tabs.add(const BodyViewTab(mode: BodyViewMode.image, label: 'Image'));
      }
    }
    if (tabs.isEmpty) {
      tabs.add(const BodyViewTab(mode: BodyViewMode.raw, label: 'Raw'));
    }
    return tabs;
  }

  Widget _buildTabContent(BodyViewTab tab) {
    switch (tab.mode) {
      case BodyViewMode.pretty:
        return _buildPrettyView(tab);
      case BodyViewMode.raw:
        return _buildRawView();
      case BodyViewMode.hex:
        return _buildHexView();
      case BodyViewMode.image:
        return _buildImageView();
    }
  }

  Widget _buildPrettyView(BodyViewTab tab) {
    final fullContent = _prettyText(tab.language);
    if (fullContent == null) {
      if (_isPrettyTooLarge) {
        return _buildLargePayloadNotice(
          'Body is larger than 1MB. Use copy or the Raw tab.',
        );
      }
      return _buildEmptyState('Unable to format body');
    }

    final isTruncated = fullContent.length > maxPreviewLength;
    final content = isTruncated
        ? fullContent.substring(0, maxPreviewLength)
        : fullContent;

    return SingleChildScrollView(
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

    return SingleChildScrollView(
      child: SelectableText(
        _cachedHex!,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          height: 1.4,
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
    switch (tab.mode) {
      case BodyViewMode.pretty:
        final pretty = _prettyText(tab.language);
        if (pretty != null) return pretty;
        return _hasText ? widget.bodyText : null;
      case BodyViewMode.raw:
        final text =
            widget.bodyText ??
            (_hasBytes
                ? utf8.decode(widget.bodyBytes!, allowMalformed: true)
                : null);
        return text?.isEmpty ?? true ? null : text;
      case BodyViewMode.hex:
        if (!_hasBytes) return null;
        _cachedHex ??= _buildHexDump(widget.bodyBytes!);
        return _cachedHex;
      case BodyViewMode.image:
        return null;
    }
  }

  String? _prettyText(String? language) {
    if (!_hasText) return null;
    if (_cachedPretty != null) return _cachedPretty;

    final text = widget.bodyText!;
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
