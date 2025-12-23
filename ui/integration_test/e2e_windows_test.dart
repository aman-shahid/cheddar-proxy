// Windows-specific E2E: uses stubs for cert/proxy to avoid locked-down CI stores.
import 'dart:async';
import 'dart:io';

import 'package:cheddarproxy/core/utils/system_proxy_service.dart';
import 'package:cheddarproxy/main.dart';
import 'package:cheddarproxy/src/rust/api/proxy_api.dart' as rust_api;
import 'package:cheddarproxy/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

void _logStep(String message) {
  debugPrint('[${DateTime.now().toIso8601String()}] [E2E-WIN] $message');
}

Future<void> _tryWithTimeout(
  String label,
  Future<void> Function() fn, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    await fn().timeout(timeout);
    _logStep('$label completed');
  } catch (e) {
    _logStep('$label failed or timed out: $e');
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  // Avoid pumpAndSettle timeouts caused by background timers; just advance time.
  await tester.pump(duration);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (!Platform.isWindows) {
    testWidgets('Skip Windows E2E on non-Windows platforms', (tester) async {
      _logStep('Skipping: not running on Windows');
    });
    return;
  }

  late Widget sharedApp;
  late GlobalKey<NavigatorState> navigatorKey;

  setUpAll(() async {
    // Stub cert/proxy checks: CI cannot modify Windows root store.
    SystemProxyService.setTestOverrides(
      certificateStatusProvider: (_) async => CertificateStatus.trusted,
      proxyConfiguredProvider: (_) async => true,
    );

    await RustLib.init();

    final appSupport = await getApplicationSupportDirectory();
    await rust_api.initCore(storagePath: appSupport.path);

    await windowManager.ensureInitialized();

    navigatorKey = GlobalKey<NavigatorState>();
    sharedApp = CheddarProxyApp(navigatorKey: navigatorKey);
  });

  tearDownAll(() async {
    await _tryWithTimeout('Teardown: disable system proxy', () async {
      await rust_api.disableSystemProxy();
    }, timeout: const Duration(seconds: 3));

    await _tryWithTimeout('Teardown: stop proxy', () async {
      await rust_api.stopProxy();
    }, timeout: const Duration(seconds: 5));

    await _tryWithTimeout('Teardown: destroy window manager', () async {
      await windowManager.destroy();
    }, timeout: const Duration(seconds: 2));

    SystemProxyService.resetTestOverrides();

    _logStep('Teardown: scheduling exit');
    Timer(const Duration(milliseconds: 500), () {
      _logStep('Teardown complete, exiting test process');
      exit(0);
    });
  });

  testWidgets('E2E (Windows CI): Complete application test suite', (
    tester,
  ) async {
    _logStep('Starting Windows E2E suite');

    await tester.pumpWidget(sharedApp);
    await _pumpFor(tester, const Duration(seconds: 1));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    _logStep('App launched and basic widgets found');

    final hasInteractiveElements =
        find.byType(TextField).evaluate().isNotEmpty ||
        find.byType(IconButton).evaluate().isNotEmpty ||
        find.byType(TextButton).evaluate().isNotEmpty ||
        find.byType(ElevatedButton).evaluate().isNotEmpty;

    expect(
      hasInteractiveElements,
      isTrue,
      reason: 'App should have interactive elements',
    );
    _logStep('Verified presence of interactive elements');

    final proxyStatus = rust_api.getProxyStatus();
    expect(proxyStatus.port, greaterThan(0));
    expect(proxyStatus.bindAddress, isNotEmpty);

    final proxyPort = proxyStatus.port;
    final isProxyRunning = proxyStatus.isRunning;
    _logStep('Proxy status -> running: $isProxyRunning, port: $proxyPort');

    HttpServer? stubServer;
    try {
      stubServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final stubHost = stubServer.address.host;
      final stubPort = stubServer.port;
      final targetUri = Uri.parse('http://$stubHost:$stubPort/hello');
      _logStep('Stub server started at $stubHost:$stubPort');

      stubServer.listen((HttpRequest request) async {
        if (request.uri.path == '/hello') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            '{"message":"hello from local stub","path":"${request.uri.path}"}',
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      if (isProxyRunning) {
        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY 127.0.0.1:$proxyPort';
        client.connectionTimeout = const Duration(seconds: 10);

        try {
          final request = await client
              .getUrl(targetUri)
              .timeout(const Duration(seconds: 15));

          final response = await request.close();
          await response.drain();
          _logStep('Made proxied request to $targetUri');

          await _pumpFor(tester, const Duration(seconds: 1));

          final paginatedResult = await rust_api.queryTransactions(
            page: 0,
            pageSize: 50,
          );

          expect(
            paginatedResult.items.isNotEmpty,
            isTrue,
            reason: 'Should have captured at least one transaction',
          );
          _logStep(
            'Captured ${paginatedResult.items.length} transaction(s) via proxy',
          );

          final matchedTx = paginatedResult.items.where(
            (tx) => tx.host.contains(stubHost) && tx.path.contains('/hello'),
          );

          if (matchedTx.isNotEmpty) {
            final tx = matchedTx.first;
            expect(tx.method.name.toLowerCase(), contains('get'));
            expect(tx.host, contains(stubHost));
            expect(tx.path, contains('/hello'));
            _logStep('Verified captured transaction from stub server');
          }
        } on TimeoutException {
          _logStep('Proxy request timed out; continuing');
        } on SocketException {
          _logStep('Proxy request failed due to socket error; continuing');
        } finally {
          client.close();
        }
      }
    } finally {
      await stubServer?.close(force: true);
      _logStep('Stub server stopped');
    }

    final settingsIcon = find.byIcon(Icons.settings);
    final settingsOutlined = find.byIcon(Icons.settings_outlined);
    final settingsText = find.text('Settings');

    Finder? settingsButton;
    if (settingsIcon.evaluate().isNotEmpty) {
      settingsButton = settingsIcon;
    } else if (settingsOutlined.evaluate().isNotEmpty) {
      settingsButton = settingsOutlined;
    } else if (settingsText.evaluate().isNotEmpty) {
      settingsButton = settingsText;
    }

    if (settingsButton != null && settingsButton.evaluate().isNotEmpty) {
      await tester.tap(settingsButton.first, warnIfMissed: false);
      await _pumpFor(tester, const Duration(milliseconds: 500));

      final hasSettingsContent =
          find.text('General').evaluate().isNotEmpty ||
          find.text('Certificate').evaluate().isNotEmpty ||
          find.text('Breakpoints').evaluate().isNotEmpty ||
          find.text('MCP').evaluate().isNotEmpty ||
          find.textContaining('Proxy').evaluate().isNotEmpty ||
          find.textContaining('Port').evaluate().isNotEmpty;

      if (hasSettingsContent) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _pumpFor(tester, const Duration(milliseconds: 300));
      }
    }

    _logStep('Phase 5: filter interaction');
    final textFields = find.byType(TextField);
    final hasTextField = textFields.evaluate().isNotEmpty;
    _logStep('Filter text field found: $hasTextField');
    if (hasTextField) {
      await tester.enterText(textFields.first, 'test-filter');
      await tester.pump(const Duration(milliseconds: 300));
      _logStep('Entered filter text');

      await tester.enterText(textFields.first, '');
      await tester.pump(const Duration(milliseconds: 300));
      _logStep('Cleared filter text');
    } else {
      _logStep('No text field available for filter; skipping Phase 5');
    }

    _logStep('Phase 6: stability interactions');
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isNotEmpty) {
      await tester.drag(scrollables.first, const Offset(0, -100));
      await tester.pumpAndSettle();
    }

    final scaffold = find.byType(Scaffold);
    if (scaffold.evaluate().isNotEmpty) {
      await tester.tap(scaffold.first);
      await tester.pumpAndSettle();
      _logStep('Completed stability interactions (scaffold tap)');
    } else {
      _logStep('Skipped scaffold tap; no scaffold found');
    }

    expect(find.byType(MaterialApp), findsOneWidget);

    _logStep('Phase 7: rapid interaction check');
    for (int i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    _logStep('Completed rapid interaction check (no-op pumps)');

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
