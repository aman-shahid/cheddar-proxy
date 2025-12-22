import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cheddarproxy/core/models/http_transaction.dart';
import 'package:cheddarproxy/core/models/traffic_state.dart';
import 'package:cheddarproxy/core/utils/system_proxy_service.dart';

HttpTransaction buildTransaction({
  required String id,
  required String host,
  required int status,
  DateTime? timestamp,
}) {
  final requestBodyBytes = Uint8List.fromList('{"id":"$id"}'.codeUnits);
  final responseBodyBytes = Uint8List.fromList('{"status":$status}'.codeUnits);

  return HttpTransaction(
    id: id,
    timestamp: timestamp ?? DateTime.now(),
    method: 'GET',
    scheme: 'https',
    host: host,
    path: '/v1/items',
    port: 443,
    requestHeaders: const {'Accept': 'application/json'},
    requestBody: String.fromCharCodes(requestBodyBytes),
    requestBodyBytes: requestBodyBytes,
    requestContentType: 'application/json',
    statusCode: status,
    statusMessage: 'OK',
    responseHeaders: const {'Content-Type': 'application/json'},
    responseBody: String.fromCharCodes(responseBodyBytes),
    responseBodyBytes: responseBodyBytes,
    responseContentType: 'application/json',
    responseSize: responseBodyBytes.length,
    duration: const Duration(milliseconds: 80),
    state: TransactionState.completed,
    isBreakpointed: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(SystemProxyService.resetTestOverrides);

  test(
    'addOrUpdateTransaction keeps single row per ID and updates selection',
    () {
      final state = TrafficState();
      final original = buildTransaction(
        id: 'dup',
        host: 'api.example.com',
        status: 200,
      );
      final updated = original.copyWith(
        statusCode: 500,
        responseBody: '{"status":500}',
      );

      state.addOrUpdateTransaction(original);
      state.selectTransaction(original);
      state.addOrUpdateTransaction(updated);

      expect(state.transactions.length, 1);
      expect(state.transactions.first.statusCode, 500);
      expect(state.selectedTransaction?.statusCode, 500);
    },
  );

  test(
    'exportHarToPath and importHarFromFile round-trip transactions',
    () async {
      final state = TrafficState();
      state.addOrUpdateTransaction(
        buildTransaction(
          id: 'a',
          host: 'service.one',
          status: 201,
          timestamp: DateTime(2024, 1, 1, 12, 0, 0),
        ),
      );
      state.addOrUpdateTransaction(
        buildTransaction(
          id: 'b',
          host: 'service.two',
          status: 404,
          timestamp: DateTime(2024, 1, 1, 13, 0, 0),
        ),
      );

      final tempDir = await Directory.systemTemp.createTemp(
        'cheddarproxy_test',
      );
      final exportPath = '${tempDir.path}/session.har';

      final exported = await state.exportHarToPath(
        outputPath: exportPath,
        filteredOnly: false,
      );

      expect(exported, 2);
      expect(File(exportPath).existsSync(), isTrue);

      final restoredState = TrafficState();
      final importedCount = await restoredState.importHarFromFile(exportPath);

      expect(importedCount, 2);
      expect(restoredState.transactions.length, 2);
      expect(restoredState.transactions.first.host, 'service.two');
    },
  );

  test('setFilter narrows filteredTransactions', () {
    final state = TrafficState();
    state.addOrUpdateTransaction(
      buildTransaction(id: '1', host: 'api.alpha.dev', status: 200),
    );
    state.addOrUpdateTransaction(
      buildTransaction(id: '2', host: 'cdn.beta.dev', status: 200),
    );

    state.setFilter(const TransactionFilter(host: 'alpha'));
    expect(state.filteredTransactions.length, 1);
    expect(state.filteredTransactions.first.host, 'api.alpha.dev');
  });

  test(
    'clearAll wipes transactions and selection with single notification',
    () {
      final state = TrafficState();
      state.addOrUpdateTransaction(
        buildTransaction(id: '1', host: 'service', status: 200),
      );
      state.selectTransaction(state.transactions.first);

      var notifications = 0;
      state.addListener(() => notifications++);
      state.clearAll();

      expect(state.transactions, isEmpty);
      expect(state.selectedTransaction, isNull);
      expect(notifications, 1);
    },
  );

  test('addTransactionsBatch keeps newest first and deduplicates IDs', () {
    final state = TrafficState();
    final older = buildTransaction(
      id: 'dup',
      host: 'api.one',
      status: 200,
      timestamp: DateTime(2024, 1, 1, 12),
    );
    final newer = buildTransaction(
      id: 'dup',
      host: 'api.one',
      status: 500,
      timestamp: DateTime(2024, 1, 1, 13),
    );
    final other = buildTransaction(
      id: 'other',
      host: 'api.two',
      status: 201,
      timestamp: DateTime(2024, 1, 1, 14),
    );

    state.addTransactionsBatch([older, other]);
    state.addTransactionsBatch([newer]);

    expect(state.transactions.length, 2);
    expect(state.transactions.first.id, 'other');
    expect(state.transactions.last.id, 'dup');
    expect(state.transactions.last.statusCode, 500);
  });

  test('proxy and certificate status reflect override values', () async {
    final state = TrafficState();
    state.setStoragePathForTest('/tmp');
    state.setRecordingStateForTest(true);
    state.setSkipRustCallsForTest(true); // Skip Rust FFI calls in unit tests

    SystemProxyService.setTestOverrides(
      certificateStatusProvider: (_) async => CertificateStatus.notTrusted,
      proxyConfiguredProvider: (_) async => false,
    );
    await state.runProxyStatusCheckForTest();
    expect(state.certStatus, CertificateStatus.notTrusted);
    expect(state.isSystemProxyEnabled, isFalse);

    SystemProxyService.setTestOverrides(
      certificateStatusProvider: (_) async => CertificateStatus.trusted,
      proxyConfiguredProvider: (_) async => true,
    );
    state.resetCertCacheForTest(); // Reset cache to pick up new override
    await state.runProxyStatusCheckForTest();
    expect(state.certStatus, CertificateStatus.trusted);
    expect(state.isSystemProxyEnabled, isTrue);
  });
}
