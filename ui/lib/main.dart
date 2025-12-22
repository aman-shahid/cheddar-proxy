// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:macos_ui/macos_ui.dart';

import 'core/theme/app_theme.dart';
import 'core/theme/theme_notifier.dart';
import 'core/models/traffic_state.dart';

import 'features/traffic_list/traffic_list_view.dart';
import 'features/request_detail/request_detail_panel.dart';
import 'features/filters/filter_bar.dart';
import 'widgets/status_bar.dart';
import 'widgets/app_toolbar.dart';
import 'widgets/about_dialog.dart';
import 'widgets/windows_menu_bar.dart';
import 'widgets/update_dialog.dart'; // Contains UpdateBanner
import 'core/utils/system_proxy_service.dart';
import 'core/utils/logger_service.dart';
import 'widgets/confirmation_dialog.dart';
import 'core/utils/update_service.dart';
import 'features/composer/composer_state.dart';
import 'features/composer/composer_panel.dart';

// Rust FFI imports
import 'src/rust/frb_generated.dart';
import 'src/rust/api/proxy_api.dart' as rust_api;

final GlobalKey<NavigatorState> _appNavigatorKey = GlobalKey<NavigatorState>();
const MethodChannel _platformChannel = MethodChannel(
  'com.cheddarproxy/platform',
);

// Global callback for triggering update check from macOS menu
VoidCallback? _globalUpdateCheckCallback;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize logging
  await LoggerService.init();

  // Initialize Rust core
  await RustLib.init();

  // Setup application storage path
  final appSupport = await getApplicationSupportDirectory();
  final storagePath = appSupport.path;

  // Initialize the Rust core with storage path for file logging
  try {
    await rust_api.initCore(storagePath: storagePath);
    LoggerService.info(
      'Cheddar Proxy Rust core initialized: v${rust_api.getVersion()}',
    );
  } catch (e) {
    LoggerService.warn('Failed to initialize Rust core: $e');
  }

  // Initialize window manager for desktop
  await windowManager.ensureInitialized();

  // Setup window properties
  const windowOptions = WindowOptions(
    size: Size(1200, 800),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'Cheddar Proxy',
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // Check unique instance
  if (!await _checkSingleInstance()) {
    LoggerService.warn('Another instance is already running.');
    exit(0);
  }

  // Register platform-specific handlers (e.g. macOS menu items)
  _registerPlatformHandlers(_appNavigatorKey);

  runApp(CheddarProxyApp(navigatorKey: _appNavigatorKey));
}

/// Check if this is the only instance of Cheddar Proxy running.
/// Uses a lock file approach for cross-platform compatibility.
Future<bool> _checkSingleInstance() async {
  try {
    final appSupport = await getApplicationSupportDirectory();
    final lockFile = File('${appSupport.path}/cheddarproxy.lock');
    final currentPid = pid;

    if (await lockFile.exists()) {
      // Check if the PID in the lock file is still running
      final pidString = await lockFile.readAsString();
      final pid = int.tryParse(pidString.trim());

      if (pid != null && pid != currentPid && _isProcessRunning(pid)) {
        // Another instance is running
        debugPrint('Cheddar Proxy is already running (PID: $pid)');
        return false;
      }
    }

    // Create/update lock file with our PID
    await lockFile.writeAsString('$currentPid');
    return true;
  } catch (e) {
    debugPrint('Single instance check failed: $e');
    // If we can't check, allow running (fail-open)
    return true;
  }
}

class _CertificateWarningContent extends StatelessWidget {
  final bool isMac;
  final VoidCallback onViewCertificate;

  const _CertificateWarningContent({
    required this.isMac,
    required this.onViewCertificate,
  });

  @override
  Widget build(BuildContext context) {
    final removalText = isMac
        ? 'To remove later: Open Keychain Access, select the System keychain, and delete "Cheddar Proxy CA" from Certificates.'
        : 'To remove later: Search "Manage computer certificates" in Windows and delete "Cheddar Proxy CA" from Trusted Root Certification Authorities.';

    final title = isMac
        ? 'Install and Trust the Cheddar Proxy CA Certificate in Keychain Access'
        : 'Install and Trust the Cheddar Proxy CA Certificate in Certificate Manager';
    const subtitle =
        'Installing and trusting the Cheddar Proxy CA Certificate, allows Cheddar Proxy to decrypt encrypted traffic - i.e. lets you inspect raw HTTPS requests and responses.';

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        const Text(subtitle, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        TextButton(
          onPressed: onViewCertificate,
          child: const Text('View certificate'),
        ),
        const SizedBox(height: 16),
        Text(
          removalText,
          style: TextStyle(
            fontSize: 12,
            color: isMac
                ? MacosColors.systemGrayColor.withValues(alpha: 0.8)
                : Colors.grey,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 460, maxWidth: 560),
      child: SingleChildScrollView(child: content),
    );
  }
}

/// Check if a process with the given PID is running.
bool _isProcessRunning(int pid) {
  try {
    if (Platform.isWindows) {
      final result = Process.runSync('tasklist', ['/FI', 'PID eq $pid']);
      return result.stdout.toString().contains(pid.toString());
    } else {
      // macOS/Linux: check if process exists
      final result = Process.runSync('kill', ['-0', pid.toString()]);
      return result.exitCode == 0;
    }
  } catch (e) {
    return false;
  }
}

/// Clean up the lock file when the app exits.
Future<void> _cleanupLockFile() async {
  try {
    final appSupport = await getApplicationSupportDirectory();
    final lockFile = File('${appSupport.path}/cheddarproxy.lock');
    if (await lockFile.exists()) {
      await lockFile.delete();
    }
  } catch (e) {
    debugPrint('Failed to cleanup lock file: $e');
  }
}

class CheddarProxyApp extends StatelessWidget {
  const CheddarProxyApp({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeNotifier()),
        ChangeNotifierProvider(create: (_) => TrafficState()..initialize()),
        ChangeNotifierProvider(create: (_) => ComposerState()),
      ],
      child: Consumer<ThemeNotifier>(
        builder: (context, themeNotifier, _) {
          return MaterialApp(
            navigatorKey: navigatorKey,
            title: 'Cheddar Proxy',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeNotifier.themeMode,
            home: Theme(data: themeNotifier.theme, child: const MainWindow()),
          );
        },
      ),
    );
  }
}

void _registerPlatformHandlers(GlobalKey<NavigatorState> navigatorKey) {
  if (!Platform.isMacOS) return;

  _platformChannel.setMethodCallHandler((call) async {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    switch (call.method) {
      case 'showAboutPanel':
        CheddarProxyAboutDialog.show(context);
      case 'checkForUpdates':
        _globalUpdateCheckCallback?.call();
    }
  });
}

class MainWindow extends StatefulWidget {
  const MainWindow({super.key});

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> with WindowListener {
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _mainFocusNode = FocusNode();
  final GlobalKey<TrafficListViewState> _trafficListKey =
      GlobalKey<TrafficListViewState>();
  final ScrollController _trafficListScrollController = ScrollController();
  ThemeNotifier? _themeNotifier;
  Color? _lastWindowBackgroundColor;
  double _dividerPosition = 0.55; // 55% for traffic list, 45% for detail panel
  UpdateInfo? _availableUpdate;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    // Register global callback for macOS menu
    _globalUpdateCheckCallback = _manualCheckForUpdates;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = context.read<ThemeNotifier>();
      _themeNotifier = notifier;
      notifier.addListener(_handleThemeChange);
      _handleThemeChange();
      // Check for updates after app is ready
      _checkForUpdates();
    });
  }

  Future<void> _checkForUpdates() async {
    final update = await UpdateService.checkForUpdate();
    if (update != null && mounted) {
      setState(() => _availableUpdate = update);
    }
  }

  /// Manual check from menu - shows feedback to user
  Future<void> _manualCheckForUpdates() async {
    final update = await UpdateService.checkForUpdate();
    if (!mounted) return;

    if (update != null) {
      setState(() => _availableUpdate = update);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You\'re up to date!'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _dismissUpdate() {
    setState(() => _availableUpdate = null);
  }

  @override
  void onWindowClose() async {
    final state = context.read<TrafficState>();
    // Try to disable proxy if enabled
    if (state.isSystemProxyEnabled) {
      debugPrint("Cleaning up system proxy settings...");
      await state.disableSystemProxy();
    }
    if (state.clearOnQuit) {
      try {
        await state.clearAll();
      } catch (e) {
        LoggerService.warn('Failed to clear transactions on quit: $e');
      }
    }
    // Clean up lock file for single instance check
    await _cleanupLockFile();
    await windowManager.destroy();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _searchFocusNode.dispose();
    _mainFocusNode.dispose();
    _trafficListScrollController.dispose();
    _themeNotifier?.removeListener(_handleThemeChange);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Update theme notifier with system brightness
    final brightness = MediaQuery.of(context).platformBrightness;
    // Defer to next microtask to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<ThemeNotifier>().updateSystemBrightness(brightness);
      }
    });
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    final isMacOS = Platform.isMacOS;
    final isMeta = HardwareKeyboard.instance.isMetaPressed;
    final isControl = HardwareKeyboard.instance.isControlPressed;
    final isModifier = isMacOS ? isMeta : isControl;

    if (!isModifier) return false;

    // Cmd+K / Ctrl+K - Search
    if (event.logicalKey == LogicalKeyboardKey.keyK) {
      _searchFocusNode.requestFocus();
      return true;
    }

    // Cmd+A / Ctrl+A - Select All
    if (event.logicalKey == LogicalKeyboardKey.keyA) {
      context.read<TrafficState>().selectAll();
      return true;
    }

    // Cmd+Space / Ctrl+Space - Record
    if (event.logicalKey == LogicalKeyboardKey.space) {
      context.read<TrafficState>().toggleRecording();
      return true;
    }

    // Cmd+Delete / Ctrl+Delete / Cmd+Backspace - Clear All
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      context.read<TrafficState>().clearAll();
      return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;
    final theme = Theme.of(context);

    // Get theme-aware colors
    final backgroundColor = isDark
        ? AppColors.background
        : AppColorsLight.background;
    final dividerColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final dividerHandleColor = isDark
        ? AppColors.textMuted.withValues(alpha: 0.5)
        : AppColorsLight.textMuted.withValues(alpha: 0.5);
    final storagePath = context.read<TrafficState>().storagePath;

    final titleBarColor =
        theme.appBarTheme.backgroundColor ??
        (isDark ? AppColors.surface : AppColorsLight.surface);
    final titleBarTextColor =
        theme.appBarTheme.foregroundColor ??
        (isDark ? AppColors.textSecondary : AppColorsLight.textSecondary);
    _updateWindowBackground(titleBarColor);

    return Scaffold(
      backgroundColor: backgroundColor,
      body: Focus(
        focusNode: _mainFocusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Column(
          children: [
            // Custom title bar for macOS/Windows
            _CustomTitleBar(
              isDark: isDark,
              backgroundColor: titleBarColor,
              foregroundColor: titleBarTextColor,
              onCheckForUpdates: _manualCheckForUpdates,
              storagePath: storagePath,
            ),

            // App toolbar
            const AppToolbar(),

            // Certificate warning banner (shows when not trusted and after initial check completes)
            Consumer<TrafficState>(
              builder: (context, state, child) {
                if (!state.shouldShowCertWarning) {
                  return const SizedBox.shrink();
                }
                return _CertificateWarningBanner(
                  status: state.certStatus,
                  storagePath: state.storagePath,
                  isDark: isDark,
                );
              },
            ),

            // Update banner (shows when update available)
            if (_availableUpdate != null)
              UpdateBanner(
                update: _availableUpdate!,
                onDismiss: _dismissUpdate,
              ),

            // Filter bar
            FilterBar(focusNode: _searchFocusNode),

            // Main content area with split view
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Row(
                    children: [
                      // Traffic list
                      SizedBox(
                        width: constraints.maxWidth * _dividerPosition,
                        child: TrafficListView(
                          key: _trafficListKey,
                          verticalScrollController:
                              _trafficListScrollController,
                          mainFocusNode: _mainFocusNode,
                        ),
                      ),

                      // Draggable divider with integrated scrollbar
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              _dividerPosition +=
                                  details.delta.dx / constraints.maxWidth;
                              _dividerPosition = _dividerPosition.clamp(
                                0.3,
                                0.7,
                              );
                            });
                          },
                          child: Container(
                            width: 14, // Wider to accommodate scrollbar
                            color: dividerColor,
                            child: Column(
                              children: [
                                // Header height area (just divider, no scrollbar)
                                // Header is ~26px padding + divider
                                const SizedBox(height: 27),
                                // Scrollbar area (fills remaining space)
                                Expanded(
                                  child: Stack(
                                    children: [
                                      // Custom scroll indicator
                                      _ScrollIndicator(
                                        scrollController:
                                            _trafficListScrollController,
                                        thumbColor: dividerHandleColor,
                                      ),
                                      // Drag handle - 6 dots grid (2 columns × 3 rows)
                                      Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            for (
                                              int row = 0;
                                              row < 3;
                                              row++
                                            ) ...[
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Container(
                                                    width: 3,
                                                    height: 3,
                                                    decoration: BoxDecoration(
                                                      color: dividerHandleColor
                                                          .withValues(
                                                            alpha: 0.8,
                                                          ),
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 3),
                                                  Container(
                                                    width: 3,
                                                    height: 3,
                                                    decoration: BoxDecoration(
                                                      color: dividerHandleColor
                                                          .withValues(
                                                            alpha: 0.8,
                                                          ),
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              if (row < 2)
                                                const SizedBox(height: 3),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Request detail panel OR Composer panel
                      Expanded(
                        child: Consumer2<TrafficState, ComposerState>(
                          builder: (context, trafficState, composerState, _) {
                            // Show composer when open, detail panel otherwise
                            if (composerState.isOpen) {
                              return const ComposerPanel();
                            }
                            return RequestDetailPanel(
                              transaction: trafficState.selectedTransaction,
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            // Status bar
            const StatusBar(),
          ],
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // Handle both initial key press and repeated key events (when held down)
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // Check if a text field has focus - if so, let it handle
    // Delete/Backspace keys for text editing, not row deletion.
    // We check if the focus is inside a TextField by looking at ancestors
    final primaryFocus = FocusManager.instance.primaryFocus;
    final focusContext = primaryFocus?.context;
    final focusedWidget = focusContext?.widget;

    // Check if focus is inside a TextField (more reliable than checking for EditableText)
    final isEditingText =
        focusedWidget is EditableText ||
        (focusContext != null &&
            focusContext.findAncestorWidgetOfExactType<TextField>() != null);

    // If editing text, don't intercept Delete/Backspace
    if (isEditingText) {
      if (event.logicalKey == LogicalKeyboardKey.delete ||
          event.logicalKey == LogicalKeyboardKey.backspace) {
        return KeyEventResult.ignored; // Let the text field handle it
      }
    }

    final state = context.read<TrafficState>();
    final transactions = state.filteredTransactions;
    if (transactions.isEmpty) return KeyEventResult.ignored;

    final isMacOS = Platform.isMacOS;
    final isMeta = HardwareKeyboard.instance.isMetaPressed;

    // Get current selection index
    final currentIndex = state.selectedTransaction != null
        ? transactions.indexOf(state.selectedTransaction!)
        : -1;

    int? newIndex;

    // Home/End keys (Windows/Linux) or Cmd+Up/Cmd+Down (macOS) - Jump to first/last
    if (event.logicalKey == LogicalKeyboardKey.home ||
        (isMacOS && isMeta && event.logicalKey == LogicalKeyboardKey.arrowUp)) {
      // Jump to first request
      newIndex = 0;
    } else if (event.logicalKey == LogicalKeyboardKey.end ||
        (isMacOS &&
            isMeta &&
            event.logicalKey == LogicalKeyboardKey.arrowDown)) {
      // Jump to last request
      newIndex = transactions.length - 1;
    }
    // Page Up/Page Down - Jump by ~20 items (roughly a visible page)
    else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
      const pageSize = 20;
      newIndex = (currentIndex - pageSize).clamp(0, transactions.length - 1);
    } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
      const pageSize = 20;
      newIndex = (currentIndex + pageSize).clamp(0, transactions.length - 1);
    }
    // Arrow keys - Navigate requests one at a time
    else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      // If no selection, start from the last item
      if (currentIndex < 0) {
        newIndex = transactions.length - 1;
      } else {
        newIndex = (currentIndex - 1).clamp(0, transactions.length - 1);
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      // If no selection, start from the first item
      if (currentIndex < 0) {
        newIndex = 0;
      } else {
        newIndex = (currentIndex + 1).clamp(0, transactions.length - 1);
      }
    }

    // Apply selection if we determined a new index
    if (newIndex != null) {
      state.selectTransaction(transactions[newIndex]);

      // Scroll the selected item into view
      _trafficListKey.currentState?.scrollToIndex(
        newIndex,
        transactions.length,
      );

      return KeyEventResult.handled;
    }

    // Delete/Backspace (without modifier) - Delete selected
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      // Only delete if no modifier is pressed (Cmd/Ctrl+Delete clears all)
      if (!isMeta && !HardwareKeyboard.instance.isControlPressed) {
        if (state.selectedCount > 0) {
          _confirmAndDeleteSelected(context, state);
          return KeyEventResult.handled;
        }
      }
    }

    return KeyEventResult.ignored;
  }

  Future<void> _confirmAndDeleteSelected(
    BuildContext context,
    TrafficState state,
  ) async {
    final count = state.selectedCount;
    if (count == 0) return;

    final message = count == 1
        ? 'Are you sure you want to delete this request?'
        : 'Are you sure you want to delete $count requests?';

    final confirmed = await showDeleteConfirmation(
      context: context,
      message: message,
    );

    if (!confirmed) return;

    state.deleteSelected();
  }

  void _updateWindowBackground(Color color) {
    if (Platform.isIOS || Platform.isAndroid) return;
    if (_lastWindowBackgroundColor == color) return;
    _lastWindowBackgroundColor = color;
    if (!mounted) return;
    unawaited(windowManager.setBackgroundColor(color));
  }

  void _handleThemeChange() {
    final notifier = _themeNotifier;
    if (notifier == null) return;
    final color = notifier.mode == AppThemeMode.light
        ? AppColorsLight.surface
        : AppColors.surface;
    _updateWindowBackground(color);
  }
}

/// Custom title bar for desktop platforms
class _CustomTitleBar extends StatelessWidget {
  final bool isDark;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback? onCheckForUpdates;
  final String? storagePath;

  const _CustomTitleBar({
    required this.isDark,
    required this.backgroundColor,
    required this.foregroundColor,
    this.onCheckForUpdates,
    this.storagePath,
  });

  @override
  Widget build(BuildContext context) {
    // Windows/Linux implementation using WindowCaption
    if (!Platform.isMacOS) {
      return SizedBox(
        height: 32,
        child: WindowCaption(
          brightness: isDark ? Brightness.dark : Brightness.light,
          backgroundColor: backgroundColor,
          title: WindowsMenuBar(
            isDark: isDark,
            foregroundColor: foregroundColor,
            onCheckForUpdates: onCheckForUpdates,
            storagePath: storagePath,
          ),
        ),
      );
    }

    // macOS implementation
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async {
        // Toggle maximize/restore on double-tap (standard macOS behavior)
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      child: Container(
        height: 28,
        color: backgroundColor,
        child: const Row(
          children: [
            // Window controls area (macOS traffic lights)
            SizedBox(width: 80),

            // Draggable title area
            Expanded(child: SizedBox()),

            // Right padding
            SizedBox(width: 80),
          ],
        ),
      ),
    );
  }
}

/// Certificate warning banner shown when certificate is not trusted
class _CertificateWarningBanner extends StatelessWidget {
  final CertificateStatus status;
  final String? storagePath;
  final bool isDark;

  const _CertificateWarningBanner({
    required this.status,
    required this.storagePath,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    String message;
    if (status == CertificateStatus.notInstalled) {
      message =
          'HTTPS interception requires a trusted certificate. Install & trust the Cheddar Proxy CA certificate to capture encrypted traffic.';
    } else if (status == CertificateStatus.mismatch) {
      message =
          'The trusted certificate in your keychain does not match the one on disk. Reinstall to fix HTTPS interception.';
    } else {
      message =
          'The Cheddar Proxy CA certificate is installed but not trusted. Trust it to enable HTTPS interception.';
    }

    final buttonText = status == CertificateStatus.notInstalled
        ? 'Install & Trust Certificate'
        : 'Reinstall & Trust';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.redirect.withValues(alpha: 0.15)
            : AppColors.redirect.withValues(alpha: 0.1),
        border: Border(
          bottom: BorderSide(
            color: AppColors.redirect.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: AppColors.redirect,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: isDark
                    ? AppColors.textPrimary
                    : AppColorsLight.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: storagePath == null
                ? null
                : () =>
                      _showCertificateConfirmationDialog(context, storagePath!),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.redirect,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }
}

/// Show confirmation dialog before installing Root CA certificate
Future<void> _showCertificateConfirmationDialog(
  BuildContext context,
  String storagePath,
) async {
  final certPath = '$storagePath/${SystemProxyService.caFileName}';
  await SystemProxyService.removeExistingCertificate();
  final installed = await SystemProxyService.installCertificateToLoginKeychain(
    certPath,
  );
  if (!installed) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not add certificate to login keychain.'),
        backgroundColor: Colors.redAccent,
      ),
    );
    return;
  }

  bool? confirmed;
  void viewCertificate() {
    SystemProxyService.viewCertificateFile(certPath);
  }

  if (Platform.isMacOS) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final macTheme = MacosThemeData(
      brightness: isDark ? Brightness.dark : Brightness.light,
    );

    confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => MacosTheme(
        data: macTheme,
        child: MacosAlertDialog(
          appIcon: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.primary, AppColors.primaryLight],
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              CupertinoIcons.lock_fill,
              color: Colors.white,
              size: 30,
            ),
          ),
          title: const Text('Install CA Certificate?'),
          message: _CertificateWarningContent(
            isMac: true,
            onViewCertificate: viewCertificate,
          ),
          primaryButton: PushButton(
            controlSize: ControlSize.large,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Install & Trust'),
          ),
          secondaryButton: PushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
        ),
      ),
    );
  } else {
    confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.security, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Text('Install CA Certificate?'),
          ],
        ),
        content: _CertificateWarningContent(
          isMac: false,
          onViewCertificate: viewCertificate,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('I Understand, Install'),
          ),
        ],
      ),
    );
  }

  if (confirmed == true) {
    final trusted = await SystemProxyService.trustAndImportCertificate(
      certPath,
    );
    if (trusted && context.mounted) {
      await context.read<TrafficState>().refreshCertificateStatusNow();
    }
  }
}

/// Custom scroll indicator that listens to a scroll controller
/// and renders a thumb without needing its own ScrollPosition.
class _ScrollIndicator extends StatefulWidget {
  const _ScrollIndicator({
    required this.scrollController,
    required this.thumbColor,
  });

  final ScrollController scrollController;
  final Color thumbColor;

  @override
  State<_ScrollIndicator> createState() => _ScrollIndicatorState();
}

class _ScrollIndicatorState extends State<_ScrollIndicator> {
  bool _isHovered = false;
  bool _isDragging = false;
  double? _dragStartY;
  double? _dragStartScrollOffset;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScrollChanged);
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScrollChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(_ScrollIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScrollChanged);
      widget.scrollController.addListener(_onScrollChanged);
    }
  }

  void _onScrollChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final controller = widget.scrollController;

        // If controller has no clients, don't show thumb
        if (!controller.hasClients) {
          return const SizedBox.expand();
        }

        // Get position safely - may have 0 or multiple positions during rebuilds
        final positions = controller.positions;
        if (positions.isEmpty || positions.length > 1) {
          return const SizedBox.expand();
        }

        final position = positions.first;
        final viewportHeight = constraints.maxHeight;
        final contentHeight =
            position.maxScrollExtent + position.viewportDimension;

        // If content fits in viewport, no need for scrollbar
        if (contentHeight <= viewportHeight || position.maxScrollExtent <= 0) {
          return const SizedBox.expand();
        }

        // Calculate thumb size and position
        final thumbHeight = (viewportHeight / contentHeight * viewportHeight)
            .clamp(30.0, viewportHeight);
        final scrollableTrackHeight = viewportHeight - thumbHeight;
        final scrollProgress = position.pixels / position.maxScrollExtent;
        final thumbTop = scrollProgress * scrollableTrackHeight;

        final thumbWidth = (_isHovered || _isDragging) ? 8.0 : 6.0;
        final thumbOpacity = _isDragging ? 1.0 : (_isHovered ? 0.8 : 0.5);

        return MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (details) {
              setState(() {
                _isDragging = true;
                _dragStartY = details.localPosition.dy;
                _dragStartScrollOffset = position.pixels;
              });
            },
            onVerticalDragUpdate: (details) {
              if (_dragStartY == null || _dragStartScrollOffset == null) return;

              final dragDelta = details.localPosition.dy - _dragStartY!;
              final scrollDelta =
                  dragDelta / scrollableTrackHeight * position.maxScrollExtent;
              final newOffset = (_dragStartScrollOffset! + scrollDelta).clamp(
                0.0,
                position.maxScrollExtent,
              );

              controller.jumpTo(newOffset);
            },
            onVerticalDragEnd: (_) {
              setState(() {
                _isDragging = false;
                _dragStartY = null;
                _dragStartScrollOffset = null;
              });
            },
            child: SizedBox.expand(
              child: Stack(
                children: [
                  Positioned(
                    top: thumbTop,
                    left: (14 - thumbWidth) / 2, // Center in the 14px divider
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      width: thumbWidth,
                      height: thumbHeight,
                      decoration: BoxDecoration(
                        color: widget.thumbColor.withValues(
                          alpha: thumbOpacity,
                        ),
                        borderRadius: BorderRadius.circular(thumbWidth / 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
