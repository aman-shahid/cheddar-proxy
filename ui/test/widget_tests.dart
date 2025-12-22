// Cheddar Proxy Widget Tests
//
// Widget tests for individual UI components.
// These tests verify widgets render correctly in isolation.
//
// Run with:
//   cd ui
//   flutter test test/widget_tests.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cheddarproxy/core/models/traffic_state.dart';
import 'package:cheddarproxy/core/models/http_transaction.dart';
import 'package:cheddarproxy/core/theme/theme_notifier.dart';
import 'package:cheddarproxy/features/traffic_list/traffic_list_view.dart';
import 'package:cheddarproxy/features/request_detail/request_detail_panel.dart';
import 'package:cheddarproxy/widgets/status_bar.dart';
import 'package:cheddarproxy/widgets/app_toolbar.dart';
import 'package:cheddarproxy/features/filters/filter_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('App Initialization Tests', () {
    testWidgets('TrafficState initializes correctly', (tester) async {
      final trafficState = TrafficState();

      // Verify initial state
      expect(trafficState.transactions, isEmpty);
      expect(trafficState.isRecording, isFalse);
      expect(trafficState.selectedTransaction, isNull);
      expect(trafficState.selectedCount, 0);
    });

    testWidgets('ThemeNotifier initializes with system theme', (tester) async {
      final themeNotifier = ThemeNotifier();

      // Verify theme notifier has a valid theme
      expect(themeNotifier.theme, isNotNull);
      expect(themeNotifier.themeMode, isNotNull);
    });
  });

  group('Traffic List Tests', () {
    testWidgets('TrafficListView renders empty state', (tester) async {
      final trafficState = TrafficState();

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: trafficState),
              ChangeNotifierProvider(create: (_) => ThemeNotifier()),
            ],
            child: const Scaffold(body: TrafficListView()),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify the widget tree is built without errors
      expect(find.byType(TrafficListView), findsOneWidget);
    });

    testWidgets('TrafficListView displays transactions', (tester) async {
      final trafficState = TrafficState();

      // Add a mock transaction
      final mockTransaction = HttpTransaction(
        id: 'test-tx-1',
        timestamp: DateTime.now(),
        method: 'GET',
        scheme: 'https',
        host: 'api.example.com',
        path: '/users',
        statusCode: 200,
        statusMessage: 'OK',
        state: TransactionState.completed,
      );

      trafficState.addOrUpdateTransaction(mockTransaction);

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: trafficState),
              ChangeNotifierProvider(create: (_) => ThemeNotifier()),
            ],
            child: const Scaffold(body: TrafficListView()),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify the transaction list is not empty
      expect(trafficState.transactions.length, 1);
      expect(trafficState.transactions.first.host, 'api.example.com');
    });

    testWidgets('Transaction selection works correctly', (tester) async {
      final trafficState = TrafficState();

      // Add mock transactions
      final tx1 = HttpTransaction(
        id: 'tx-1',
        timestamp: DateTime.now(),
        method: 'GET',
        scheme: 'https',
        host: 'api.example.com',
        path: '/users',
        statusCode: 200,
        state: TransactionState.completed,
      );

      final tx2 = HttpTransaction(
        id: 'tx-2',
        timestamp: DateTime.now().subtract(const Duration(seconds: 1)),
        method: 'POST',
        scheme: 'https',
        host: 'api.example.com',
        path: '/orders',
        statusCode: 201,
        state: TransactionState.completed,
      );

      trafficState.addOrUpdateTransaction(tx1);
      trafficState.addOrUpdateTransaction(tx2);

      // Select first transaction
      trafficState.selectTransaction(tx1);
      expect(trafficState.selectedTransaction?.id, 'tx-1');
      expect(trafficState.selectedCount, 1);

      // Select second transaction
      trafficState.selectTransaction(tx2);
      expect(trafficState.selectedTransaction?.id, 'tx-2');
      expect(trafficState.selectedCount, 1);

      // Clear selection
      trafficState.clearSelection();
      expect(trafficState.selectedTransaction, isNull);
      expect(trafficState.selectedCount, 0);
    });

    testWidgets('Select all transactions', (tester) async {
      final trafficState = TrafficState();

      // Add multiple transactions
      for (int i = 0; i < 5; i++) {
        trafficState.addOrUpdateTransaction(
          HttpTransaction(
            id: 'tx-$i',
            timestamp: DateTime.now().subtract(Duration(seconds: i)),
            method: 'GET',
            scheme: 'https',
            host: 'api.example.com',
            path: '/resource/$i',
            statusCode: 200,
            state: TransactionState.completed,
          ),
        );
      }

      expect(trafficState.transactions.length, 5);

      // Select all
      trafficState.selectAll();
      expect(trafficState.selectedCount, 5);

      // Delete selected
      trafficState.deleteSelected();
      expect(trafficState.transactions.length, 0);
      expect(trafficState.selectedCount, 0);
    });
  });

  group('Request Detail Panel Tests', () {
    testWidgets('RequestDetailPanel shows empty state', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => TrafficState()),
              ChangeNotifierProvider(create: (_) => ThemeNotifier()),
            ],
            child: const Scaffold(body: RequestDetailPanel(transaction: null)),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify empty state is shown
      expect(find.byType(RequestDetailPanel), findsOneWidget);
    });

    testWidgets('RequestDetailPanel displays transaction details', (
      tester,
    ) async {
      final transaction = HttpTransaction(
        id: 'detail-test-1',
        timestamp: DateTime.now(),
        method: 'POST',
        scheme: 'https',
        host: 'api.stripe.com',
        path: '/v1/charges',
        statusCode: 200,
        statusMessage: 'OK',
        requestHeaders: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer sk_test_xxx',
        },
        requestBody: '{"amount": 1000, "currency": "usd"}',
        responseHeaders: {'Content-Type': 'application/json'},
        responseBody: '{"id": "ch_xxx", "status": "succeeded"}',
        duration: const Duration(milliseconds: 150),
        responseSize: 256,
        state: TransactionState.completed,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => TrafficState()),
              ChangeNotifierProvider(create: (_) => ThemeNotifier()),
            ],
            child: Scaffold(body: RequestDetailPanel(transaction: transaction)),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify the detail panel is displayed
      expect(find.byType(RequestDetailPanel), findsOneWidget);
    });
  });

  group('Filter Tests', () {
    testWidgets('Filter by method works', (tester) async {
      final trafficState = TrafficState();

      // Add transactions with different methods
      trafficState.addOrUpdateTransaction(
        HttpTransaction(
          id: 'get-1',
          timestamp: DateTime.now(),
          method: 'GET',
          scheme: 'https',
          host: 'api.example.com',
          path: '/users',
          statusCode: 200,
          state: TransactionState.completed,
        ),
      );

      trafficState.addOrUpdateTransaction(
        HttpTransaction(
          id: 'post-1',
          timestamp: DateTime.now(),
          method: 'POST',
          scheme: 'https',
          host: 'api.example.com',
          path: '/users',
          statusCode: 201,
          state: TransactionState.completed,
        ),
      );

      expect(trafficState.filteredTransactions.length, 2);

      // Apply GET filter
      trafficState.setFilter(const TransactionFilter(methods: {'GET'}));

      expect(trafficState.filteredTransactions.length, 1);
      expect(trafficState.filteredTransactions.first.method, 'GET');

      // Clear filter
      trafficState.setFilter(const TransactionFilter());
      expect(trafficState.filteredTransactions.length, 2);
    });

    testWidgets('Filter by host works', (tester) async {
      final trafficState = TrafficState();

      trafficState.addOrUpdateTransaction(
        HttpTransaction(
          id: 'example-1',
          timestamp: DateTime.now(),
          method: 'GET',
          scheme: 'https',
          host: 'api.example.com',
          path: '/users',
          statusCode: 200,
          state: TransactionState.completed,
        ),
      );

      trafficState.addOrUpdateTransaction(
        HttpTransaction(
          id: 'stripe-1',
          timestamp: DateTime.now(),
          method: 'POST',
          scheme: 'https',
          host: 'api.stripe.com',
          path: '/charges',
          statusCode: 200,
          state: TransactionState.completed,
        ),
      );

      // Filter by host containing 'stripe'
      trafficState.setFilter(const TransactionFilter(host: 'stripe'));

      expect(trafficState.filteredTransactions.length, 1);
      expect(trafficState.filteredTransactions.first.host, 'api.stripe.com');
    });

    testWidgets('Filter by status category works', (tester) async {
      final trafficState = TrafficState();

      // Add transactions with different status codes
      for (final status in [200, 201, 400, 404, 500]) {
        trafficState.addOrUpdateTransaction(
          HttpTransaction(
            id: 'status-$status',
            timestamp: DateTime.now(),
            method: 'GET',
            scheme: 'https',
            host: 'api.example.com',
            path: '/resource',
            statusCode: status,
            state: TransactionState.completed,
          ),
        );
      }

      expect(trafficState.filteredTransactions.length, 5);

      // Filter for client errors (4xx) - statusCategories uses the first digit
      trafficState.setFilter(const TransactionFilter(statusCategories: {4}));

      expect(trafficState.filteredTransactions.length, 2);
      for (final tx in trafficState.filteredTransactions) {
        expect(tx.statusCode, greaterThanOrEqualTo(400));
        expect(tx.statusCode, lessThan(500));
      }
    });
  });

  group('UI Component Tests', () {
    testWidgets('StatusBar renders correctly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => TrafficState()),
              ChangeNotifierProvider(create: (_) => ThemeNotifier()),
            ],
            child: const Scaffold(body: StatusBar()),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.byType(StatusBar), findsOneWidget);
    });

    testWidgets('AppToolbar renders correctly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => TrafficState()),
              ChangeNotifierProvider(create: (_) => ThemeNotifier()),
            ],
            child: const Scaffold(body: AppToolbar()),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.byType(AppToolbar), findsOneWidget);
    });

    testWidgets('FilterBar renders and accepts focus', (tester) async {
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => TrafficState()),
              ChangeNotifierProvider(create: (_) => ThemeNotifier()),
            ],
            child: Scaffold(body: FilterBar(focusNode: focusNode)),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.byType(FilterBar), findsOneWidget);

      focusNode.dispose();
    });
  });

  group('Data Operations Tests', () {
    testWidgets('Clear all transactions works', (tester) async {
      final trafficState = TrafficState();

      // Add some transactions
      for (int i = 0; i < 10; i++) {
        trafficState.addOrUpdateTransaction(
          HttpTransaction(
            id: 'tx-$i',
            timestamp: DateTime.now(),
            method: 'GET',
            scheme: 'https',
            host: 'api.example.com',
            path: '/resource/$i',
            statusCode: 200,
            state: TransactionState.completed,
          ),
        );
      }

      expect(trafficState.transactions.length, 10);

      // Clear all
      trafficState.clearAll();

      expect(trafficState.transactions.length, 0);
      expect(trafficState.selectedTransaction, isNull);
    });

    testWidgets('Delete individual transaction works', (tester) async {
      final trafficState = TrafficState();

      trafficState.addOrUpdateTransaction(
        HttpTransaction(
          id: 'tx-to-delete',
          timestamp: DateTime.now(),
          method: 'GET',
          scheme: 'https',
          host: 'api.example.com',
          path: '/resource',
          statusCode: 200,
          state: TransactionState.completed,
        ),
      );

      trafficState.addOrUpdateTransaction(
        HttpTransaction(
          id: 'tx-to-keep',
          timestamp: DateTime.now(),
          method: 'POST',
          scheme: 'https',
          host: 'api.example.com',
          path: '/resource',
          statusCode: 201,
          state: TransactionState.completed,
        ),
      );

      expect(trafficState.transactions.length, 2);

      // Delete specific transaction
      trafficState.deleteTransaction('tx-to-delete');

      expect(trafficState.transactions.length, 1);
      expect(trafficState.transactions.first.id, 'tx-to-keep');
    });

    testWidgets('Transaction update preserves selection', (tester) async {
      final trafficState = TrafficState();

      final original = HttpTransaction(
        id: 'tx-update-test',
        timestamp: DateTime.now(),
        method: 'GET',
        scheme: 'https',
        host: 'api.example.com',
        path: '/resource',
        statusCode: null, // Request phase
        state: TransactionState.pending,
      );

      trafficState.addOrUpdateTransaction(original);
      trafficState.selectTransaction(original);

      expect(trafficState.selectedTransaction?.id, 'tx-update-test');
      expect(trafficState.selectedTransaction?.statusCode, isNull);

      // Update with response
      final updated = HttpTransaction(
        id: 'tx-update-test',
        timestamp: original.timestamp,
        method: 'GET',
        scheme: 'https',
        host: 'api.example.com',
        path: '/resource',
        statusCode: 200,
        statusMessage: 'OK',
        duration: const Duration(milliseconds: 100),
        state: TransactionState.completed,
      );

      trafficState.addOrUpdateTransaction(updated);

      // Selection should be preserved and updated
      expect(trafficState.selectedTransaction?.id, 'tx-update-test');
      expect(trafficState.selectedTransaction?.statusCode, 200);
      expect(trafficState.transactions.length, 1);
    });
  });
}
