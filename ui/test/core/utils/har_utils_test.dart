import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cheddarproxy/core/models/http_transaction.dart';
import 'package:cheddarproxy/core/utils/har_utils.dart';

void main() {
  HttpTransaction buildTransaction({
    required String id,
    required String method,
    required String host,
    required String path,
    required int status,
    Uint8List? requestBytes,
    Uint8List? responseBytes,
  }) {
    final now = DateTime.now();
    final requestBodyBytes =
        requestBytes ?? Uint8List.fromList('{"payload":"$id"}'.codeUnits);
    final responseBodyBytes =
        responseBytes ?? Uint8List.fromList('{"ok":true}'.codeUnits);

    return HttpTransaction(
      id: id,
      timestamp: now,
      method: method,
      scheme: 'https',
      host: host,
      path: path,
      port: 443,
      query: 'page=1',
      requestHeaders: {'Content-Type': 'application/json'},
      requestBody: String.fromCharCodes(requestBodyBytes),
      requestBodyBytes: requestBodyBytes,
      requestContentType: 'application/json',
      statusCode: status,
      statusMessage: 'OK',
      responseHeaders: {'Content-Type': 'application/json'},
      responseBody: String.fromCharCodes(responseBodyBytes),
      responseBodyBytes: responseBodyBytes,
      responseContentType: 'application/json',
      responseSize: responseBodyBytes.length,
      duration: const Duration(milliseconds: 120),
      state: TransactionState.completed,
      isBreakpointed: false,
    );
  }

  test('toHar/fromHar round trip preserves key fields', () {
    final tx = buildTransaction(
      id: 'tx-1',
      method: 'POST',
      host: 'api.example.com',
      path: '/login',
      status: 201,
    );

    final har = HarUtils.toHar([tx]);
    final restored = HarUtils.fromHar(har);

    expect(restored.length, 1);
    final restoredTx = restored.first;
    expect(restoredTx.method, tx.method);
    expect(restoredTx.host, tx.host);
    expect(restoredTx.path, tx.path);
    expect(restoredTx.requestBody, tx.requestBody);
    expect(restoredTx.responseBody, tx.responseBody);
    expect(restoredTx.statusCode, tx.statusCode);
  });

  test('binary bodies are exported/imported via base64 encoding', () {
    final binaryBytes = Uint8List.fromList(<int>[0, 255, 128, 64]);
    final tx = buildTransaction(
      id: 'tx-bin',
      method: 'GET',
      host: 'cdn.example.com',
      path: '/image',
      status: 200,
      responseBytes: binaryBytes,
    );

    final har = HarUtils.toHar([tx]);
    final content =
        ((har['log'] as Map)['entries'] as List).first as Map<String, dynamic>;
    final response = content['response'] as Map<String, dynamic>;
    final harContent = response['content'] as Map<String, dynamic>;
    expect(harContent['encoding'], 'base64');

    final restored = HarUtils.fromHar(har);
    final restoredTx = restored.first;
    expect(restoredTx.responseBodyBytes, binaryBytes);
    expect(restoredTx.responseBody, isNull);
  });
}
