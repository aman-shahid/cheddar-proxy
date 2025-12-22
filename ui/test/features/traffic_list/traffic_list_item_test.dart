import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:cheddarproxy/core/models/traffic_state.dart';
import 'package:cheddarproxy/core/models/http_transaction.dart';
import 'package:cheddarproxy/core/theme/theme_notifier.dart';
import 'package:cheddarproxy/features/traffic_list/traffic_list_view.dart';

/// Tests for TrafficListView widget to prevent layout overflow issues.
///
/// These tests verify that:
/// 1. The traffic list renders without overflow at various widths
/// 2. Selection state changes don't cause layout shifts
/// 3. Breakpointed transactions render correctly
///
/// IMPORTANT: These tests exist because we had a persistent 3px overflow issue
/// caused by a left border on selected rows. The fix involved:
/// 1. Always having a 3px left border (transparent when not selected)
/// 2. Wrapping the path column in Flexible to absorb extra width
void main() {
  // Helper to create mock transactions using the HttpTransaction model
  HttpTransaction createMockTransaction({
    String id = 'test-123',
    String method = 'GET',
    String host = 'api.example.com',
    String path = '/api/test',
    int? statusCode = 200,
    TransactionState state = TransactionState.completed,
  }) {
    return HttpTransaction(
      id: id,
      timestamp: DateTime.now(),
      method: method,
      scheme: 'https',
      host: host,
      path: path,
      statusCode: statusCode,
      state: state,
      isBreakpointed: state == TransactionState.breakpointed,
    );
  }

  Widget buildTestWidget({
    required TrafficState trafficState,
    double width = 800,
  }) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 600,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<TrafficState>.value(value: trafficState),
              ChangeNotifierProvider<ThemeNotifier>(
                create: (_) => ThemeNotifier(),
              ),
            ],
            child: const TrafficListView(),
          ),
        ),
      ),
    );
  }

  group('TrafficListView Overflow Prevention Tests', () {
    testWidgets('renders without overflow with single transaction', (
      tester,
    ) async {
      final state = TrafficState();
      final tx = createMockTransaction();
      state.addOrUpdateTransaction(tx);

      await tester.pumpWidget(
        buildTestWidget(trafficState: state, width: 1000),
      );
      await tester.pumpAndSettle();

      // Verify widget rendered
      expect(find.text(tx.host), findsOneWidget);

      // Check no exceptions were thrown (including overflow)
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders without overflow at narrow width', (tester) async {
      final state = TrafficState();
      state.addOrUpdateTransaction(createMockTransaction());

      // Test with narrow width
      await tester.pumpWidget(
        buildTestWidget(
          trafficState: state,
          width: 600, // Narrow width
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders without overflow with many transactions', (
      tester,
    ) async {
      final state = TrafficState();

      // Add multiple transactions
      for (int i = 0; i < 20; i++) {
        state.addOrUpdateTransaction(createMockTransaction(id: 'tx-$i'));
      }

      await tester.pumpWidget(
        buildTestWidget(trafficState: state, width: 1000),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders breakpointed transactions correctly', (tester) async {
      final state = TrafficState();
      state.addOrUpdateTransaction(
        createMockTransaction(
          id: 'breakpointed',
          state: TransactionState.breakpointed,
        ),
      );

      await tester.pumpWidget(
        buildTestWidget(trafficState: state, width: 1000),
      );
      await tester.pumpAndSettle();

      // Verify breakpoint indicator
      expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('selection does not cause overflow', (tester) async {
      final state = TrafficState();
      final tx = createMockTransaction();
      state.addOrUpdateTransaction(tx);

      await tester.pumpWidget(
        buildTestWidget(trafficState: state, width: 1000),
      );
      await tester.pumpAndSettle();

      // Tap to select
      await tester.tap(find.text(tx.host));
      await tester.pumpAndSettle();

      // Verify selection worked without overflow
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders with very long paths without overflow', (
      tester,
    ) async {
      final state = TrafficState();
      state.addOrUpdateTransaction(
        createMockTransaction(
          path:
              '/very/long/path/that/is/much/longer/than/the/available/column/width',
        ),
      );

      await tester.pumpWidget(buildTestWidget(trafficState: state, width: 800));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders with very long hosts without overflow', (
      tester,
    ) async {
      final state = TrafficState();
      state.addOrUpdateTransaction(
        createMockTransaction(
          host: 'subdomain.very-long-domain-name.extremely.long.example.com',
        ),
      );

      await tester.pumpWidget(buildTestWidget(trafficState: state, width: 800));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('TrafficListView Selection Border Tests', () {
    testWidgets('handles minimum width gracefully', (tester) async {
      final state = TrafficState();
      state.addOrUpdateTransaction(createMockTransaction());

      // Very narrow width - should still render without error
      await tester.pumpWidget(buildTestWidget(trafficState: state, width: 400));
      await tester.pumpAndSettle();

      // May have visual issues but should not throw
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling selection does not throw', (tester) async {
      final state = TrafficState();
      final tx = createMockTransaction();
      state.addOrUpdateTransaction(tx);

      await tester.pumpWidget(
        buildTestWidget(trafficState: state, width: 1000),
      );
      await tester.pumpAndSettle();

      // Select
      await tester.tap(find.text(tx.host));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Deselect by tapping again (if that's how it works) or add another
      state.selectTransaction(null);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
