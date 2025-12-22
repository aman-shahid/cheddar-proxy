import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:cheddarproxy/features/request_detail/request_detail_panel.dart'
    show BodyViewer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrapWithScaffold(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  testWidgets('renders Pretty/Raw tabs for JSON text', (tester) async {
    final jsonBody = '{"foo": "bar","count":1}';
    final widget = wrapWithScaffold(
      BodyViewer(
        bodyText: jsonBody,
        bodyBytes: Uint8List.fromList(utf8.encode(jsonBody)),
        contentType: 'application/json',
        isDark: false,
      ),
    );

    await tester.pumpWidget(widget);
    expect(find.text('Pretty'), findsOneWidget);
    expect(find.text('Raw'), findsOneWidget);
    expect(find.byType(HighlightView), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);

    // Switch to Raw tab and ensure raw JSON text is visible.
    await tester.tap(find.text('Raw'));
    await tester.pumpAndSettle();

    final rawText = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(rawText.data, jsonBody);
  });

  testWidgets('shows Hex/Image tabs and handles invalid image data', (
    tester,
  ) async {
    final bytes = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final widget = wrapWithScaffold(
      BodyViewer(
        bodyText: null,
        bodyBytes: bytes,
        contentType: 'image/png',
        isDark: true,
      ),
    );

    await tester.pumpWidget(widget);

    expect(find.text('Hex'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);

    // Switch to Image tab and ensure graceful error message.
    await tester.tap(find.text('Image'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Unable to render image data'), findsOneWidget);
  });
}
