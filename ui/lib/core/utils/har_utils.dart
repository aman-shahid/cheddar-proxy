import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../models/http_transaction.dart';

class HarUtils {
  HarUtils._();

  static const String _harVersion = '1.2';
  static const String _creatorName = 'Cheddar Proxy';
  static const String _creatorVersion = '0.0.1';

  static int _idCounter = 0;

  static Map<String, dynamic> toHar(List<HttpTransaction> transactions) {
    return {
      'log': {
        'version': _harVersion,
        'creator': {'name': _creatorName, 'version': _creatorVersion},
        'entries': transactions.map(_entryFromTransaction).toList(),
      },
    };
  }

  static List<HttpTransaction> fromHar(Map<String, dynamic> json) {
    final log = json['log'];
    if (log is! Map<String, dynamic>) {
      throw const FormatException('HAR log missing');
    }
    final entries = log['entries'];
    if (entries is! List) {
      throw const FormatException('HAR entries missing');
    }

    return entries
        .whereType<Map<String, dynamic>>()
        .map(_transactionFromEntry)
        .whereType<HttpTransaction>()
        .toList();
  }

  static Map<String, dynamic> _entryFromTransaction(HttpTransaction tx) {
    final uri = Uri.tryParse(tx.fullUrl);
    final started = tx.timestamp.toUtc().toIso8601String();
    final time = tx.duration?.inMilliseconds ?? 0;
    return {
      'startedDateTime': started,
      'time': time,
      'request': _requestFromTransaction(tx, uri),
      'response': _responseFromTransaction(tx),
      'cache': const {},
      'timings': {'send': 0, 'wait': time, 'receive': 0},
    };
  }

  static Map<String, dynamic> _requestFromTransaction(
    HttpTransaction tx,
    Uri? uri,
  ) {
    final headers = tx.requestHeaders.entries
        .map((e) => {'name': e.key, 'value': e.value})
        .toList();
    final queryItems = <Map<String, String>>[];
    if (uri != null && uri.hasQuery) {
      uri.queryParametersAll.forEach((key, values) {
        for (final value in values) {
          queryItems.add({'name': key, 'value': value});
        }
      });
    }
    final postData = _encodeBody(
      tx.requestBodyBytes,
      tx.requestBody,
      tx.requestContentType,
    );
    return {
      'method': tx.method,
      'url': tx.fullUrl,
      'httpVersion': 'HTTP/1.1',
      'headers': headers,
      'queryString': queryItems,
      'cookies': const [],
      'headersSize': -1,
      'bodySize': postData?['text'] != null
          ? (tx.requestBodyBytes?.length ?? postData!['text'].length)
          : 0,
      if (postData != null) 'postData': postData,
    };
  }

  static Map<String, dynamic> _responseFromTransaction(HttpTransaction tx) {
    final headers = (tx.responseHeaders ?? {}).entries
        .map((e) => {'name': e.key, 'value': e.value})
        .toList();
    final content = _encodeBody(
      tx.responseBodyBytes,
      tx.responseBody,
      tx.responseContentType,
    );
    final size =
        tx.responseSize ??
        tx.responseBodyBytes?.length ??
        content?['text']?.length ??
        0;
    return {
      'status': tx.statusCode ?? 0,
      'statusText': tx.statusMessage ?? '',
      'httpVersion': 'HTTP/1.1',
      'headers': headers,
      'cookies': const [],
      'content': {
        'size': size,
        'mimeType': tx.responseContentType ?? '',
        if (content != null) ...content,
      },
      'redirectURL': '',
      'headersSize': -1,
      'bodySize': size,
    };
  }

  static Map<String, dynamic>? _encodeBody(
    Uint8List? bytes,
    String? fallbackText,
    String? mimeType,
  ) {
    if (bytes == null || bytes.isEmpty) {
      if (fallbackText == null || fallbackText.isEmpty) {
        return null;
      }
      return {'mimeType': mimeType ?? 'text/plain', 'text': fallbackText};
    }
    try {
      final text = utf8.decode(bytes);
      return {'mimeType': mimeType ?? 'text/plain', 'text': text};
    } catch (_) {
      return {
        'mimeType': mimeType ?? 'application/octet-stream',
        'text': base64Encode(bytes),
        'encoding': 'base64',
      };
    }
  }

  static HttpTransaction? _transactionFromEntry(Map<String, dynamic> entry) {
    final request = entry['request'];
    if (request is! Map<String, dynamic>) {
      return null;
    }
    final response = entry['response'] as Map<String, dynamic>?;
    final startedStr = entry['startedDateTime'] as String?;
    DateTime timestamp;
    try {
      timestamp = startedStr != null
          ? DateTime.parse(startedStr).toLocal()
          : DateTime.now();
    } catch (_) {
      timestamp = DateTime.now();
    }
    final urlStr = request['url'] as String? ?? '';
    final uri = Uri.tryParse(urlStr);

    final query = uri?.hasQuery == true ? uri!.query : null;
    final path = uri?.path.isNotEmpty == true ? uri!.path : '/';
    final method = (request['method'] as String? ?? 'GET').toUpperCase();
    final headers = _headersToMap(request['headers']);
    final postData = request['postData'] as Map<String, dynamic>?;
    final requestBody = _decodeHarBody(postData);
    final respContent = response?['content'] as Map<String, dynamic>?;
    final responseBody = _decodeHarBody(respContent);

    final durationMs = (entry['time'] as num?)?.round();
    final statusCode = (response?['status'] as num?)?.toInt();

    return HttpTransaction(
      id: _generateLocalId(),
      timestamp: timestamp,
      method: method,
      scheme: uri?.scheme ?? 'http',
      host: uri?.host ?? '',
      path: path,
      query: query,
      port: (uri?.port != null && uri!.port != 0)
          ? uri.port
          : (uri?.scheme == 'https' ? 443 : 80),
      requestHeaders: headers,
      requestBody: requestBody.text,
      requestContentType: postData?['mimeType'] as String?,
      requestBodyBytes: requestBody.bytes,
      statusCode: statusCode,
      statusMessage: response?['statusText'] as String?,
      responseHeaders: _headersToMap(response?['headers']),
      responseBody: responseBody.text,
      responseBodyBytes: responseBody.bytes,
      responseContentType: respContent?['mimeType'] as String?,
      responseSize:
          (respContent?['size'] as num?)?.toInt() ?? responseBody.bytes?.length,
      duration: durationMs != null
          ? Duration(milliseconds: max(durationMs, 0))
          : null,
      state: statusCode != null
          ? TransactionState.completed
          : TransactionState.pending,
      isBreakpointed: false,
    );
  }

  static Map<String, String> _headersToMap(dynamic headers) {
    if (headers is! List) return {};
    final map = <String, String>{};
    for (final header in headers.whereType<Map>()) {
      final name = header['name'];
      final value = header['value'];
      if (name is String && value is String) {
        map[name] = value;
      }
    }
    return map;
  }

  static _BodyData _decodeHarBody(Map<String, dynamic>? section) {
    if (section == null) {
      return const _BodyData();
    }
    final encoding = section['encoding'] as String?;
    final text = section['text'] as String?;
    if (text == null) {
      return const _BodyData();
    }
    if (encoding?.toLowerCase() == 'base64') {
      try {
        final bytes = base64Decode(text);
        try {
          final decoded = utf8.decode(bytes);
          return _BodyData(text: decoded, bytes: bytes);
        } catch (_) {
          return _BodyData(bytes: bytes);
        }
      } catch (_) {
        return const _BodyData();
      }
    } else {
      return _BodyData(
        text: text,
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
    }
  }

  static String _generateLocalId() {
    _idCounter = (_idCounter + 1) % 1000000;
    return 'har-${DateTime.now().millisecondsSinceEpoch}$_idCounter';
  }
}

class _BodyData {
  const _BodyData({this.text, this.bytes});
  final String? text;
  final Uint8List? bytes;
}
