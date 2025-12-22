import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cheddarproxy/core/models/traffic_state.dart';
import 'package:cheddarproxy/core/theme/theme_notifier.dart';
import 'package:cheddarproxy/features/filters/filter_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Keyboard Focus Detection Tests', () {
    testWidgets(
      'TextField ancestor detection returns true when focused on search field',
      (tester) async {
        // This tests the exact logic used in main.dart to detect if user is editing text
        final searchFocusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextField(focusNode: searchFocusNode, autofocus: true),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Get the primary focus and check if TextField is in ancestors
        // This is the SAME check used in _handleKeyEvent in main.dart
        final primaryFocus = FocusManager.instance.primaryFocus;
        final focusContext = primaryFocus?.context;
        final focusedWidget = focusContext?.widget;

        final isEditingText =
            focusedWidget is EditableText ||
            (focusContext != null &&
                focusContext.findAncestorWidgetOfExactType<TextField>() !=
                    null);

        expect(
          isEditingText,
          isTrue,
          reason: 'Should detect TextField when search field is focused',
        );

        searchFocusNode.dispose();
      },
    );

    testWidgets(
      'TextField ancestor detection returns false when focused on regular Focus widget',
      (tester) async {
        // This tests that non-TextField focus doesn't trigger text editing detection
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Focus(
                focusNode: focusNode,
                autofocus: true,
                child: const Text('Not a TextField'),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Same check as main.dart
        final primaryFocus = FocusManager.instance.primaryFocus;
        final focusContext = primaryFocus?.context;
        final focusedWidget = focusContext?.widget;

        final isEditingText =
            focusedWidget is EditableText ||
            (focusContext != null &&
                focusContext.findAncestorWidgetOfExactType<TextField>() !=
                    null);

        expect(
          isEditingText,
          isFalse,
          reason:
              'Should NOT detect TextField when regular Focus widget has focus',
        );

        focusNode.dispose();
      },
    );

    testWidgets('FilterBar contains TextField that can receive focus', (
      tester,
    ) async {
      // Test the actual FilterBar widget used in the app
      final trafficState = TrafficState();
      final searchFocusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: trafficState),
              ChangeNotifierProvider(create: (_) => ThemeNotifier()),
            ],
            child: Scaffold(body: FilterBar(focusNode: searchFocusNode)),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify TextField exists in FilterBar
      expect(find.byType(TextField), findsOneWidget);

      // Request focus on search field
      searchFocusNode.requestFocus();
      await tester.pumpAndSettle();

      // Verify it has focus
      expect(searchFocusNode.hasFocus, isTrue);

      // Now check our detection logic works with the real FilterBar
      final primaryFocus = FocusManager.instance.primaryFocus;
      final focusContext = primaryFocus?.context;

      final hasTextFieldAncestor =
          focusContext?.findAncestorWidgetOfExactType<TextField>() != null;

      expect(
        hasTextFieldAncestor,
        isTrue,
        reason:
            'FilterBar search field should be detected as TextField when focused',
      );

      searchFocusNode.dispose();
    });
  });

  group('Keyboard Event Simulation Tests', () {
    testWidgets(
      'Delete key in TextField should be ignored by custom handler (returns KeyEventResult.ignored)',
      (tester) async {
        // Simulate the scenario: user is typing in TextField and presses Delete
        // Our handler should detect TextField and return ignored to let TextField handle it
        final textController = TextEditingController(text: 'test text');
        final textFocusNode = FocusNode();
        var customHandlerCalled = false;
        var customHandlerIgnored = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Focus(
                autofocus: false,
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;

                  customHandlerCalled = true;

                  // Replicate the detection logic from main.dart
                  final primaryFocus = FocusManager.instance.primaryFocus;
                  final focusContext = primaryFocus?.context;
                  final focusedWidget = focusContext?.widget;

                  final isEditingText =
                      focusedWidget is EditableText ||
                      (focusContext != null &&
                          focusContext
                                  .findAncestorWidgetOfExactType<TextField>() !=
                              null);

                  if (isEditingText &&
                      (event.logicalKey == LogicalKeyboardKey.delete ||
                          event.logicalKey == LogicalKeyboardKey.backspace)) {
                    customHandlerIgnored = true;
                    return KeyEventResult.ignored;
                  }

                  return KeyEventResult.handled;
                },
                child: TextField(
                  focusNode: textFocusNode,
                  controller: textController,
                  autofocus: true,
                ),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Ensure TextField has focus
        expect(textFocusNode.hasFocus, isTrue);

        // Send a Delete key event
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pumpAndSettle();

        // Verify our custom handler was called and correctly ignored the event
        expect(
          customHandlerCalled,
          isTrue,
          reason: 'Custom key handler should be called',
        );
        expect(
          customHandlerIgnored,
          isTrue,
          reason:
              'Custom handler should ignore Delete when TextField is focused',
        );

        textFocusNode.dispose();
        textController.dispose();
      },
    );

    testWidgets(
      'Delete key without TextField should be handled by custom handler',
      (tester) async {
        // Simulate the scenario: user has selected a row and presses Delete
        // Our handler should handle it (not ignore)
        final mainFocusNode = FocusNode();
        var customHandlerCalled = false;
        var customHandlerHandled = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Focus(
                focusNode: mainFocusNode,
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;

                  customHandlerCalled = true;

                  // Replicate the detection logic from main.dart
                  final primaryFocus = FocusManager.instance.primaryFocus;
                  final focusContext = primaryFocus?.context;
                  final focusedWidget = focusContext?.widget;

                  final isEditingText =
                      focusedWidget is EditableText ||
                      (focusContext != null &&
                          focusContext
                                  .findAncestorWidgetOfExactType<TextField>() !=
                              null);

                  if (isEditingText &&
                      (event.logicalKey == LogicalKeyboardKey.delete ||
                          event.logicalKey == LogicalKeyboardKey.backspace)) {
                    return KeyEventResult.ignored;
                  }

                  // Would normally delete selected row here
                  if (event.logicalKey == LogicalKeyboardKey.delete ||
                      event.logicalKey == LogicalKeyboardKey.backspace) {
                    customHandlerHandled = true;
                    return KeyEventResult.handled;
                  }

                  return KeyEventResult.ignored;
                },
                child: const Text('Row content (not a TextField)'),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Ensure Focus has focus (not a TextField)
        expect(mainFocusNode.hasFocus, isTrue);

        // Send a Delete key event
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pumpAndSettle();

        // Verify our custom handler was called and handled the event
        expect(
          customHandlerCalled,
          isTrue,
          reason: 'Custom key handler should be called',
        );
        expect(
          customHandlerHandled,
          isTrue,
          reason:
              'Custom handler should handle Delete when no TextField is focused',
        );

        mainFocusNode.dispose();
      },
    );

    testWidgets(
      'Backspace key in TextField should be ignored by custom handler',
      (tester) async {
        // Same as Delete test but with Backspace key
        final textController = TextEditingController(text: 'test text');
        final textFocusNode = FocusNode();
        var customHandlerIgnored = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Focus(
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;

                  final primaryFocus = FocusManager.instance.primaryFocus;
                  final focusContext = primaryFocus?.context;
                  final focusedWidget = focusContext?.widget;

                  final isEditingText =
                      focusedWidget is EditableText ||
                      (focusContext != null &&
                          focusContext
                                  .findAncestorWidgetOfExactType<TextField>() !=
                              null);

                  if (isEditingText &&
                      (event.logicalKey == LogicalKeyboardKey.delete ||
                          event.logicalKey == LogicalKeyboardKey.backspace)) {
                    customHandlerIgnored = true;
                    return KeyEventResult.ignored;
                  }

                  return KeyEventResult.handled;
                },
                child: TextField(
                  focusNode: textFocusNode,
                  controller: textController,
                  autofocus: true,
                ),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Send a Backspace key event
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();

        expect(
          customHandlerIgnored,
          isTrue,
          reason:
              'Custom handler should ignore Backspace when TextField is focused',
        );

        textFocusNode.dispose();
        textController.dispose();
      },
    );
  });

  group('Focus Restoration Tests', () {
    testWidgets('Focus can be transferred from TextField to main Focus node', (
      tester,
    ) async {
      // Test that focus can be moved from search bar back to main area
      final mainFocusNode = FocusNode(debugLabel: 'main');
      final searchFocusNode = FocusNode(debugLabel: 'search');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              focusNode: mainFocusNode,
              child: Column(
                children: [
                  TextField(focusNode: searchFocusNode, autofocus: true),
                  const Text('Main content'),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Initially search field has focus
      expect(searchFocusNode.hasFocus, isTrue);

      // Transfer focus to main node (simulates clicking a row)
      mainFocusNode.requestFocus();
      await tester.pumpAndSettle();

      // Main should now have focus
      expect(mainFocusNode.hasFocus, isTrue);
      expect(searchFocusNode.hasFocus, isFalse);

      // Unfocus before disposing to avoid assertion error
      mainFocusNode.unfocus();
      await tester.pumpAndSettle();

      mainFocusNode.dispose();
      searchFocusNode.dispose();
    });

    testWidgets(
      'After focus transfer, Delete key should be handled (not ignored)',
      (tester) async {
        // Complete flow: focus starts in TextField, transfers to main, Delete should work
        final mainFocusNode = FocusNode(debugLabel: 'main');
        final searchFocusNode = FocusNode(debugLabel: 'search');
        var deleteHandled = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Focus(
                focusNode: mainFocusNode,
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;

                  final primaryFocus = FocusManager.instance.primaryFocus;
                  final focusContext = primaryFocus?.context;
                  final focusedWidget = focusContext?.widget;

                  final isEditingText =
                      focusedWidget is EditableText ||
                      (focusContext != null &&
                          focusContext
                                  .findAncestorWidgetOfExactType<TextField>() !=
                              null);

                  if (isEditingText &&
                      (event.logicalKey == LogicalKeyboardKey.delete ||
                          event.logicalKey == LogicalKeyboardKey.backspace)) {
                    return KeyEventResult.ignored;
                  }

                  if (event.logicalKey == LogicalKeyboardKey.delete) {
                    deleteHandled = true;
                    return KeyEventResult.handled;
                  }

                  return KeyEventResult.ignored;
                },
                child: Column(
                  children: [
                    TextField(focusNode: searchFocusNode),
                    const Text('Selected row'),
                  ],
                ),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Start with focus on TextField
        searchFocusNode.requestFocus();
        await tester.pumpAndSettle();
        expect(searchFocusNode.hasFocus, isTrue);

        // Send Delete while in TextField - should be ignored
        deleteHandled = false;
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pumpAndSettle();
        expect(
          deleteHandled,
          isFalse,
          reason: 'Delete should be ignored when TextField has focus',
        );

        // Transfer focus to main (simulates clicking a row)
        mainFocusNode.requestFocus();
        await tester.pumpAndSettle();
        expect(mainFocusNode.hasFocus, isTrue);

        // Now Delete should be handled
        deleteHandled = false;
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pumpAndSettle();
        expect(
          deleteHandled,
          isTrue,
          reason: 'Delete should be handled after focus transfers to main',
        );

        // Unfocus before disposing to avoid assertion error
        mainFocusNode.unfocus();
        await tester.pumpAndSettle();

        mainFocusNode.dispose();
        searchFocusNode.dispose();
      },
    );
  });
}
