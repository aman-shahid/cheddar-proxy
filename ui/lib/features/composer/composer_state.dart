import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../../core/models/http_transaction.dart';

/// Entry for a header in the composer
class HeaderEntry {
  String key;
  String value;
  bool enabled;

  HeaderEntry({required this.key, required this.value, this.enabled = true});

  HeaderEntry copyWith({String? key, String? value, bool? enabled}) {
    return HeaderEntry(
      key: key ?? this.key,
      value: value ?? this.value,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// Response from a composed request
class ComposerResponse {
  final int? statusCode;
  final String? statusMessage;
  final Map<String, String> headers;
  final String? body;
  final Uint8List? bodyBytes;
  final String? contentType;
  final Duration duration;
  final String? error;

  ComposerResponse({
    this.statusCode,
    this.statusMessage,
    this.headers = const {},
    this.body,
    this.bodyBytes,
    this.contentType,
    required this.duration,
    this.error,
  });

  bool get isSuccess =>
      statusCode != null && statusCode! >= 200 && statusCode! < 300;
  bool get isError =>
      error != null || (statusCode != null && statusCode! >= 400);
}

/// State for the Request Composer
class ComposerState extends ChangeNotifier {
  bool _isOpen = false;

  // Request fields
  String _method = 'GET';
  String _url = '';
  List<HeaderEntry> _headers = [];
  String _body = '';
  String _bodyContentType = 'application/json';

  // Response
  ComposerResponse? _response;
  bool _isSending = false;

  // Source transaction (if imported)
  String? _sourceTransactionId;

  // Getters
  bool get isOpen => _isOpen;
  String get method => _method;
  String get url => _url;
  List<HeaderEntry> get headers => _headers;
  String get body => _body;
  String get bodyContentType => _bodyContentType;
  ComposerResponse? get response => _response;
  bool get isSending => _isSending;
  String? get sourceTransactionId => _sourceTransactionId;

  // Quick check if request has body methods
  bool get methodSupportsBody =>
      _method == 'POST' || _method == 'PUT' || _method == 'PATCH';

  /// Toggle composer open/closed
  void toggle() {
    _isOpen = !_isOpen;
    notifyListeners();
  }

  /// Open composer
  void open() {
    if (!_isOpen) {
      _isOpen = true;
      notifyListeners();
    }
  }

  /// Close composer
  void close() {
    if (_isOpen) {
      _isOpen = false;
      notifyListeners();
    }
  }

  /// Clear and start fresh
  void clear() {
    _method = 'GET';
    _url = '';
    _headers = [];
    _body = '';
    _bodyContentType = 'application/json';
    _response = null;
    _sourceTransactionId = null;
    notifyListeners();
  }

  /// Set HTTP method
  void setMethod(String method) {
    if (_method != method) {
      _method = method;
      notifyListeners();
    }
  }

  /// Set URL
  void setUrl(String url) {
    _url = url;
    // Don't notify on every keystroke - URL field handles its own state
  }

  /// Set body
  void setBody(String body) {
    _body = body;
    // Don't notify on every keystroke
  }

  /// Set body content type
  void setBodyContentType(String contentType) {
    if (_bodyContentType != contentType) {
      _bodyContentType = contentType;
      notifyListeners();
    }
  }

  /// Add a new header
  void addHeader({String key = '', String value = ''}) {
    _headers.add(HeaderEntry(key: key, value: value));
    notifyListeners();
  }

  /// Update a header
  void updateHeader(int index, {String? key, String? value, bool? enabled}) {
    if (index >= 0 && index < _headers.length) {
      _headers[index] = _headers[index].copyWith(
        key: key,
        value: value,
        enabled: enabled,
      );
      // Only notify if enabled changed (visual change)
      if (enabled != null) {
        notifyListeners();
      }
    }
  }

  /// Remove a header
  void removeHeader(int index) {
    if (index >= 0 && index < _headers.length) {
      _headers.removeAt(index);
      notifyListeners();
    }
  }

  /// Set all headers from raw text parsing (replaces all headers)
  void setRawHeaders(List<HeaderEntry> headers) {
    _headers = headers;
    notifyListeners();
  }

  /// Import from a captured transaction
  void importFromTransaction(HttpTransaction tx) {
    _sourceTransactionId = tx.id;
    _method = tx.method;

    // Build URL
    final port = tx.port;
    final scheme = tx.scheme;
    if ((scheme == 'https' && port == 443) ||
        (scheme == 'http' && port == 80)) {
      _url = '$scheme://${tx.host}${tx.path}';
    } else {
      _url = '$scheme://${tx.host}:$port${tx.path}';
    }

    // Import headers
    _headers = tx.requestHeaders.entries
        .where(
          (e) =>
              e.key.toLowerCase() != 'host' &&
              e.key.toLowerCase() != 'content-length',
        )
        .map((e) => HeaderEntry(key: e.key, value: e.value))
        .toList();

    // Import body
    _body = tx.requestBody ?? '';

    // Detect content type
    final contentType =
        tx.requestHeaders['Content-Type'] ??
        tx.requestHeaders['content-type'] ??
        '';
    if (contentType.contains('json')) {
      _bodyContentType = 'application/json';
    } else if (contentType.contains('xml')) {
      _bodyContentType = 'application/xml';
    } else if (contentType.contains('form')) {
      _bodyContentType = 'application/x-www-form-urlencoded';
    } else {
      _bodyContentType = 'text/plain';
    }

    _response = null;
    notifyListeners();
  }

  /// Parse and import from cURL command
  bool importFromCurl(String curlCommand) {
    try {
      // Basic cURL parser
      final cmd = curlCommand.trim();
      if (!cmd.startsWith('curl')) return false;

      // Extract URL - look for http:// or https://
      final urlRegex = RegExp(r'''https?://[^\s'"]+''');
      final urlMatch = urlRegex.firstMatch(cmd);
      if (urlMatch != null) {
        _url = urlMatch.group(0) ?? '';
      }

      // Extract method
      final methodRegex = RegExp(r'-X\s+(\w+)');
      final methodMatch = methodRegex.firstMatch(cmd);
      _method = methodMatch?.group(1) ?? 'GET';

      // Extract headers
      _headers = [];
      final headerRegex = RegExp(r'''-H\s+['"]([^:]+):\s*([^'"]+)['"]''');
      final headerMatches = headerRegex.allMatches(cmd);
      for (final match in headerMatches) {
        final key = match.group(1)?.trim() ?? '';
        final value = match.group(2)?.trim() ?? '';
        if (key.isNotEmpty &&
            key.toLowerCase() != 'host' &&
            key.toLowerCase() != 'content-length') {
          _headers.add(HeaderEntry(key: key, value: value));
        }
      }

      // Extract body - improved regex to handle multi-line and quoted content
      // Try single-quoted body first
      var bodyMatch = RegExp(
        r"-d\s+'((?:[^'\\]|\\.)*)'\s*",
        dotAll: true,
      ).firstMatch(cmd);
      if (bodyMatch != null) {
        _body = bodyMatch.group(1)?.replaceAll(r"\'", "'") ?? '';
      } else {
        // Try double-quoted body
        bodyMatch = RegExp(
          r'-d\s+"((?:[^"\\]|\\.)*)"\s*',
          dotAll: true,
        ).firstMatch(cmd);
        if (bodyMatch != null) {
          _body = bodyMatch.group(1)?.replaceAll(r'\"', '"') ?? '';
        } else {
          // Try $'...' style (common in bash)
          bodyMatch = RegExp(
            r"-d\s+\$'((?:[^'\\]|\\.)*)'\s*",
            dotAll: true,
          ).firstMatch(cmd);
          if (bodyMatch != null) {
            _body =
                bodyMatch
                    .group(1)
                    ?.replaceAll(r"\'", "'")
                    .replaceAll(r'\n', '\n')
                    .replaceAll(r'\t', '\t') ??
                '';
          } else {
            // Try unquoted body (until next flag or end)
            bodyMatch = RegExp(
              r'-d\s+([^\s-][^\s]*)',
              dotAll: true,
            ).firstMatch(cmd);
            _body = bodyMatch?.group(1) ?? '';
          }
        }
      }

      // Also try --data and --data-raw variants
      if (_body.isEmpty) {
        bodyMatch = RegExp(
          r"--data(?:-raw)?\s+'((?:[^'\\]|\\.)*)'\s*",
          dotAll: true,
        ).firstMatch(cmd);
        if (bodyMatch != null) {
          _body = bodyMatch.group(1)?.replaceAll(r"\'", "'") ?? '';
        } else {
          bodyMatch = RegExp(
            r'--data(?:-raw)?\s+"((?:[^"\\]|\\.)*)"\s*',
            dotAll: true,
          ).firstMatch(cmd);
          if (bodyMatch != null) {
            _body = bodyMatch.group(1)?.replaceAll(r'\"', '"') ?? '';
          }
        }
      }

      _sourceTransactionId = null;
      _response = null;
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Build headers map for sending
  Map<String, String> buildHeadersMap() {
    final map = <String, String>{};
    for (final h in _headers) {
      if (h.enabled && h.key.isNotEmpty) {
        map[h.key] = h.value;
      }
    }
    return map;
  }

  /// Build body bytes for sending
  Uint8List? buildBodyBytes() {
    if (_body.isEmpty || !methodSupportsBody) return null;
    return Uint8List.fromList(utf8.encode(_body));
  }

  /// Set sending state
  void setSending(bool sending) {
    _isSending = sending;
    notifyListeners();
  }

  /// Set response
  void setResponse(ComposerResponse? response) {
    _response = response;
    _isSending = false;
    notifyListeners();
  }
}
