import 'dart:convert';
import 'dart:typed_data';
import 'dart:collection';
import '../../src/rust/models/transaction.dart' as rust_models;

/// Represents a captured HTTP request/response pair
class HttpTransaction {
  final String id;
  final DateTime timestamp;
  final String method;
  final String scheme;
  final String host;
  final String path;
  final String? query;
  final int? port;
  final Map<String, String> requestHeaders;
  final String? requestBody;
  final Uint8List? requestBodyBytes;
  final String? requestContentType;
  final int? statusCode;
  final String? statusMessage;
  final Map<String, String>? responseHeaders;
  final String? responseBody;
  final Uint8List? responseBodyBytes;
  final String? responseContentType;
  final int? responseSize;
  final Duration? duration;
  final TransactionState state;
  final bool isBreakpointed;
  final TransactionTiming timing;

  // Connection metadata
  final String httpVersion;
  final String? serverIp;
  final String? tlsVersion;
  final String? tlsCipher;
  final bool connectionReused;
  final bool isWebsocket;

  HttpTransaction({
    required this.id,
    required this.timestamp,
    required this.method,
    required this.scheme,
    required this.host,
    required this.path,
    this.query,
    this.port,
    this.requestHeaders = const {},
    this.requestBody,
    this.requestContentType,
    this.requestBodyBytes,
    this.statusCode,
    this.statusMessage,
    this.responseHeaders,
    this.responseBody,
    this.responseBodyBytes,
    this.responseContentType,
    this.responseSize,
    this.duration,
    this.state = TransactionState.pending,
    this.isBreakpointed = false,
    TransactionTiming? timing,
    this.httpVersion = 'HTTP/1.1',
    this.serverIp,
    this.tlsVersion,
    this.tlsCipher,
    this.connectionReused = false,
    this.isWebsocket = false,
  }) : timing = timing ?? TransactionTiming();

  /// Create from Rust-generated model
  factory HttpTransaction.fromRust(rust_models.HttpTransaction rustTx) {
    // Convert Rust HttpMethod enum to String
    // Enum values are like HttpMethod.get_, HttpMethod.post
    String methodStr = rustTx.method.toString().split('.').last.toUpperCase();
    if (methodStr.endsWith('_')) {
      methodStr = methodStr.substring(0, methodStr.length - 1);
    }

    // Convert bodies from Uint8List to String
    final reqBodyBytes = rustTx.requestBody;
    final resBodyBytes = rustTx.responseBody;
    final reqBody = _decodeBody(reqBodyBytes);
    final resBody = _decodeBody(resBodyBytes);

    // Map state
    TransactionState state;
    switch (rustTx.state) {
      case rust_models.TransactionState.pending:
        state = TransactionState.pending;
        break;
      case rust_models.TransactionState.completed:
        state = TransactionState.completed;
        break;
      case rust_models.TransactionState.failed:
        state = TransactionState.failed;
        break;
      case rust_models.TransactionState.breakpointed:
        state = TransactionState.breakpointed;
        break;
    }

    // Parse path and query
    // The path from Rust includes query string, e.g. "/path?query=1"
    String path = rustTx.path;
    String? query;
    final queryIndex = path.indexOf('?');
    if (queryIndex != -1) {
      query = path.substring(queryIndex + 1);
      path = path.substring(0, queryIndex);
    }

    return HttpTransaction(
      id: rustTx.id,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        rustTx.timing.startTime.toInt(),
      ),
      method: methodStr,
      scheme: rustTx.scheme,
      host: rustTx.host,
      port: rustTx.port,
      path: path,
      query: query,
      requestHeaders: SplayTreeMap<String, String>.from(rustTx.requestHeaders),
      requestBody: reqBody,
      requestContentType: rustTx.requestContentType,
      requestBodyBytes: reqBodyBytes,
      statusCode: rustTx.statusCode,
      statusMessage: rustTx.statusMessage,
      responseHeaders: rustTx.responseHeaders != null
          ? SplayTreeMap<String, String>.from(rustTx.responseHeaders!)
          : null,
      responseBody: resBody,
      responseBodyBytes: resBodyBytes,
      responseContentType: rustTx.responseContentType,
      responseSize: rustTx.responseSize?.toInt(),
      duration: rustTx.timing.totalMs != null
          ? Duration(milliseconds: rustTx.timing.totalMs!)
          : null,
      state: state,
      isBreakpointed: rustTx.hasBreakpoint,
      timing: TransactionTiming.fromRust(rustTx.timing),
      httpVersion: rustTx.httpVersion,
      serverIp: rustTx.serverIp,
      tlsVersion: rustTx.tlsVersion,
      tlsCipher: rustTx.tlsCipher,
      connectionReused: rustTx.connectionReused,
      isWebsocket: rustTx.isWebsocket,
    );
  }

  /// Full URL
  String get fullUrl {
    final buffer = StringBuffer()
      ..write(scheme)
      ..write('://')
      ..write(host);
    if (port != null && port != 80 && port != 443) {
      buffer.write(':$port');
    }
    buffer.write(path);
    if (query != null && query!.isNotEmpty) {
      buffer.write('?$query');
    }
    return buffer.toString();
  }

  /// Short path for display
  String get shortPath {
    if (path.length > 40) {
      return '${path.substring(0, 37)}...';
    }
    return path;
  }

  /// Duration as formatted string
  String get durationStr {
    if (duration == null) return '-';
    if (duration!.inMilliseconds < 1000) {
      return '${duration!.inMilliseconds}ms';
    }
    return '${(duration!.inMilliseconds / 1000).toStringAsFixed(2)}s';
  }

  /// Response size as formatted string
  String get sizeStr {
    if (responseSize == null) return '-';
    if (responseSize! < 1024) {
      return '${responseSize}B';
    } else if (responseSize! < 1024 * 1024) {
      return '${(responseSize! / 1024).toStringAsFixed(1)}KB';
    } else {
      return '${(responseSize! / (1024 * 1024)).toStringAsFixed(2)}MB';
    }
  }

  /// Calculate request size (headers + body)
  int get requestSize {
    int size = 0;
    // Estimate headers size
    for (final entry in requestHeaders.entries) {
      size += entry.key.length + entry.value.length + 4; // ": " + "\r\n"
    }
    // Add body size
    if (requestBodyBytes != null) {
      size += requestBodyBytes!.length;
    } else if (requestBody != null) {
      size += requestBody!.length;
    }
    return size;
  }

  /// Request size as formatted string
  String get requestSizeStr {
    final size = requestSize;
    if (size == 0) return '-';
    if (size < 1024) {
      return '${size}B';
    } else if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)}KB';
    } else {
      return '${(size / (1024 * 1024)).toStringAsFixed(2)}MB';
    }
  }

  /// Port as display string (empty if default port)
  String get portStr {
    if (port == null) return '';
    if (scheme == 'https' && port == 443) return '';
    if (scheme == 'http' && port == 80) return '';
    return ':$port';
  }

  /// Create a copy with updated values
  HttpTransaction copyWith({
    String? id,
    DateTime? timestamp,
    String? method,
    String? scheme,
    String? host,
    String? path,
    String? query,
    int? port,
    Map<String, String>? requestHeaders,
    String? requestBody,
    String? requestContentType,
    Uint8List? requestBodyBytes,
    int? statusCode,
    String? statusMessage,
    Map<String, String>? responseHeaders,
    String? responseBody,
    Uint8List? responseBodyBytes,
    String? responseContentType,
    int? responseSize,
    Duration? duration,
    TransactionState? state,
    bool? isBreakpointed,
    TransactionTiming? timing,
    String? httpVersion,
    String? serverIp,
    String? tlsVersion,
    String? tlsCipher,
    bool? connectionReused,
    bool? isWebsocket,
  }) {
    return HttpTransaction(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      method: method ?? this.method,
      scheme: scheme ?? this.scheme,
      host: host ?? this.host,
      path: path ?? this.path,
      query: query ?? this.query,
      port: port ?? this.port,
      requestHeaders: requestHeaders ?? this.requestHeaders,
      requestBody: requestBody ?? this.requestBody,
      requestContentType: requestContentType ?? this.requestContentType,
      requestBodyBytes: requestBodyBytes ?? this.requestBodyBytes,
      statusCode: statusCode ?? this.statusCode,
      statusMessage: statusMessage ?? this.statusMessage,
      responseHeaders: responseHeaders ?? this.responseHeaders,
      responseBody: responseBody ?? this.responseBody,
      responseBodyBytes: responseBodyBytes ?? this.responseBodyBytes,
      responseContentType: responseContentType ?? this.responseContentType,
      responseSize: responseSize ?? this.responseSize,
      duration: duration ?? this.duration,
      state: state ?? this.state,
      isBreakpointed: isBreakpointed ?? this.isBreakpointed,
      timing: timing ?? this.timing,
      httpVersion: httpVersion ?? this.httpVersion,
      serverIp: serverIp ?? this.serverIp,
      tlsVersion: tlsVersion ?? this.tlsVersion,
      tlsCipher: tlsCipher ?? this.tlsCipher,
      connectionReused: connectionReused ?? this.connectionReused,
      isWebsocket: isWebsocket ?? this.isWebsocket,
    );
  }

  /// Determine resource type from content type header
  ResourceType get resourceType {
    if (isWebsocket || scheme.toLowerCase().startsWith('ws')) {
      return ResourceType.websocket;
    }
    if (responseContentType == null) return ResourceType.other;
    final ct = responseContentType!.toLowerCase();

    if (ct.contains('json')) return ResourceType.json;
    if (ct.contains('xml')) return ResourceType.xml;
    if (ct.contains('html')) return ResourceType.html;
    if (ct.contains('javascript') || ct.contains('ecmascript')) {
      return ResourceType.js;
    }
    if (ct.contains('css')) return ResourceType.css;
    if (ct.contains('image')) return ResourceType.image;
    if (ct.contains('font') || ct.contains('woff') || ct.contains('ttf')) {
      return ResourceType.font;
    }
    if (ct.contains('audio') || ct.contains('video')) return ResourceType.media;

    return ResourceType.other;
  }

  bool get hasRequestBody {
    final hasText = requestBody != null && requestBody!.isNotEmpty;
    final hasBytes = requestBodyBytes != null && requestBodyBytes!.isNotEmpty;
    return hasText || hasBytes;
  }

  bool get hasResponseBody {
    final hasText = responseBody != null && responseBody!.isNotEmpty;
    final hasBytes = responseBodyBytes != null && responseBodyBytes!.isNotEmpty;
    return hasText || hasBytes;
  }

  static String? _decodeBody(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }
}

/// Timing information for an HTTP transaction
class TransactionTiming {
  final int? dnsLookupMs;
  final int? tcpConnectMs;
  final int? tlsHandshakeMs;
  final int? requestSendMs;
  final int? waitingMs;
  final int? contentDownloadMs;
  final int? totalMs;

  const TransactionTiming({
    this.dnsLookupMs,
    this.tcpConnectMs,
    this.tlsHandshakeMs,
    this.requestSendMs,
    this.waitingMs,
    this.contentDownloadMs,
    this.totalMs,
  });

  /// Create from Rust timing
  factory TransactionTiming.fromRust(rust_models.TransactionTiming rustTiming) {
    return TransactionTiming(
      dnsLookupMs: rustTiming.dnsLookupMs,
      tcpConnectMs: rustTiming.tcpConnectMs,
      tlsHandshakeMs: rustTiming.tlsHandshakeMs,
      requestSendMs: rustTiming.requestSendMs,
      waitingMs: rustTiming.waitingMs,
      contentDownloadMs: rustTiming.contentDownloadMs,
      totalMs: rustTiming.totalMs,
    );
  }
}

/// State of an HTTP transaction
enum TransactionState {
  /// Request is pending/in progress
  pending,

  /// Request completed successfully
  completed,

  /// Request failed
  failed,

  /// Request is paused at breakpoint
  breakpointed,
}

/// Common resource types
enum ResourceType {
  json,
  xml,
  html,
  js,
  css,
  image,
  font,
  media,
  websocket,
  other,
}

/// Filter criteria for transactions
class TransactionFilter {
  final String? searchText;
  final Set<String> methods;
  final Set<int> statusCategories; // 2, 3, 4, 5 for 2xx, 3xx, etc.
  final String? host;
  final Set<ResourceType> resourceTypes;

  const TransactionFilter({
    this.searchText,
    this.methods = const {},
    this.statusCategories = const {},
    this.host,
    this.resourceTypes = const {},
  });

  bool get isEmpty =>
      (searchText == null || searchText!.isEmpty) &&
      methods.isEmpty &&
      statusCategories.isEmpty &&
      (host == null || host!.isEmpty) &&
      resourceTypes.isEmpty;

  TransactionFilter copyWith({
    String? searchText,
    Set<String>? methods,
    Set<int>? statusCategories,
    String? host,
    Set<ResourceType>? resourceTypes,
  }) {
    return TransactionFilter(
      searchText: searchText ?? this.searchText,
      methods: methods ?? this.methods,
      statusCategories: statusCategories ?? this.statusCategories,
      host: host ?? this.host,
      resourceTypes: resourceTypes ?? this.resourceTypes,
    );
  }

  /// Check if a transaction matches this filter
  bool matches(HttpTransaction tx) {
    // Search text filter
    if (searchText != null && searchText!.isNotEmpty) {
      final searchLower = searchText!.toLowerCase();
      final matchesUrl = tx.fullUrl.toLowerCase().contains(searchLower);
      final matchesBody =
          tx.requestBody?.toLowerCase().contains(searchLower) ?? false;
      final matchesResponse =
          tx.responseBody?.toLowerCase().contains(searchLower) ?? false;
      if (!matchesUrl && !matchesBody && !matchesResponse) {
        return false;
      }
    }

    // Method filter
    if (methods.isNotEmpty && !methods.contains(tx.method)) {
      return false;
    }

    // Status category filter
    if (statusCategories.isNotEmpty && tx.statusCode != null) {
      final category = tx.statusCode! ~/ 100;
      if (!statusCategories.contains(category)) {
        return false;
      }
    }

    // Host filter
    if (host != null && host!.isNotEmpty) {
      if (!tx.host.toLowerCase().contains(host!.toLowerCase())) {
        return false;
      }
    }

    // Resource type filter
    if (resourceTypes.isNotEmpty) {
      if (!resourceTypes.contains(tx.resourceType)) {
        return false;
      }
    }

    return true;
  }
}
