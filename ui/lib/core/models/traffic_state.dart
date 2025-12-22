import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/http_transaction.dart';
import '../../src/rust/api/proxy_api.dart' as rust_api;
import '../utils/system_proxy_service.dart';
import '../utils/logger_service.dart';
import '../utils/har_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

enum TrafficSortField {
  requestNumber,
  timestamp,
  method,
  host,
  path,
  status,
  duration,
  size,
}

/// State provider for traffic management
class TrafficState extends ChangeNotifier {
  static const int _listBodyCacheLimit = 32 * 1024; // 32KB per body snapshot
  final List<HttpTransaction> _transactions = [];
  HttpTransaction? _selectedTransaction;
  final Set<String> _selectedTransactionIds = {}; // Multi-select support
  int? _lastSelectedIndex; // For shift+click range selection
  TransactionFilter _filter = const TransactionFilter();
  bool _isRecording = false;
  String _proxyAddress = '127.0.0.1:9090';
  CertificateStatus _certStatus = CertificateStatus.notInstalled;
  bool _hasCertCheckCompleted = false;
  bool _isInitialized = false;
  String _rustVersion = 'unknown';
  bool _isSystemProxyEnabled = false;
  Timer? _proxyCheckTimer;
  StreamSubscription?
  _trafficSubscription; // Subscription to Rust traffic stream
  String? _storagePath;
  bool _isMcpServerRunning = false;
  bool _isMcpToggleInProgress = false;
  bool _mcpAllowWrites = false;
  bool _mcpRequireApproval = true;
  String? _mcpSocketPath;
  String? _mcpLastError;
  String? _mcpToken;
  bool _isMcpTokenLoading = false;
  String? _mcpTokenError;
  bool _autoEnableMcp = false;
  bool _clearOnQuit = false;
  final Map<String, int> _requestNumbers = {};
  int _nextRequestNumber = 1;
  TrafficSortField _sortField = TrafficSortField.requestNumber;
  bool _sortAscending = false;

  // Test mode: when true, skips Rust FFI calls
  bool _skipRustCalls = false;

  // Performance: cache certificate status to avoid frequent process spawns
  DateTime? _lastCertCheck;
  static const _certCheckInterval = Duration(seconds: 30);

  static const _mcpSettingsFile = 'mcp_settings.json';

  @override
  void dispose() {
    _proxyCheckTimer?.cancel();
    _trafficSubscription?.cancel();
    super.dispose();
  }

  /// All captured transactions
  List<HttpTransaction> get transactions => List.unmodifiable(_transactions);

  /// Filtered transactions based on current filter
  List<HttpTransaction> get filteredTransactions {
    final Iterable<HttpTransaction> source = _filter.isEmpty
        ? _transactions
        : _transactions.where(_filter.matches);
    final List<HttpTransaction> results = List<HttpTransaction>.of(source);
    results.sort(_compareForSort);
    if (!_sortAscending) {
      return results.reversed.toList();
    }
    return results;
  }

  /// Currently selected transaction (primary selection for detail panel)
  HttpTransaction? get selectedTransaction => _selectedTransaction;

  /// Set of selected transaction IDs (for multi-select operations)
  Set<String> get selectedTransactionIds =>
      Set.unmodifiable(_selectedTransactionIds);

  /// Number of selected transactions
  int get selectedCount => _selectedTransactionIds.length;

  /// Check if a transaction is selected
  bool isTransactionSelected(String id) => _selectedTransactionIds.contains(id);

  /// Current filter
  TransactionFilter get filter => _filter;

  /// Whether traffic recording is active
  bool get isRecording => _isRecording;

  /// Proxy address
  String get proxyAddress => _proxyAddress;

  /// Certificate status (not installed, not trusted, trusted)
  CertificateStatus get certStatus => _certStatus;
  bool get hasCertCheckCompleted => _hasCertCheckCompleted;
  bool get shouldShowCertWarning =>
      _hasCertCheckCompleted && _certStatus != CertificateStatus.trusted;

  /// Whether CA certificate is installed and trusted (for backward compat)
  bool get isCertInstalled => _certStatus == CertificateStatus.trusted;

  /// Total number of transactions
  int get totalCount => _transactions.length;

  /// Total bytes uploaded (request headers + body)
  int get totalUploadBytes =>
      _transactions.fold(0, (sum, tx) => sum + tx.requestSize);

  /// Total bytes downloaded (response sizes)
  int get totalDownloadBytes =>
      _transactions.fold(0, (sum, tx) => sum + (tx.responseSize ?? 0));

  /// Whether the Rust core is initialized
  bool get isInitialized => _isInitialized;

  /// Whether the system proxy is correctly configured to point to Cheddar Proxy
  bool get isSystemProxyEnabled => _isSystemProxyEnabled;

  /// Version of the Rust core
  String get rustVersion => _rustVersion;

  /// Storage path for certificates and data
  String? get storagePath => _storagePath;

  bool get isMcpServerRunning => _isMcpServerRunning;
  bool get isMcpToggleInProgress => _isMcpToggleInProgress;
  bool get mcpAllowWrites => _mcpAllowWrites;
  bool get mcpRequireApproval => _mcpRequireApproval;
  String? get mcpSocketPath => _mcpSocketPath;
  String? get mcpLastError => _mcpLastError;
  String? get mcpToken => _mcpToken;
  bool get isMcpTokenLoading => _isMcpTokenLoading;
  String? get mcpTokenError => _mcpTokenError;
  bool get autoEnableMcp => _autoEnableMcp;
  bool get clearOnQuit => _clearOnQuit;
  TrafficSortField get sortField => _sortField;
  bool get sortAscending => _sortAscending;
  int requestNumberFor(HttpTransaction tx) => _requestNumbers[tx.id] ?? 0;

  /// Initialize the traffic state and connect to Rust backend
  Future<void> initialize() async {
    try {
      // Get the Rust core version
      _rustVersion = rust_api.getVersion();
      final docsDir = await getApplicationSupportDirectory();
      _storagePath = docsDir.path;
      await _notifyHostStoragePath();
      await _loadPreferences();

      // Initialize CA
      // Initialize CA
      try {
        await rust_api.ensureRootCa(storagePath: _storagePath!);
      } catch (e) {
        LoggerService.error('Failed to initialize CA: $e');
      }

      // Prune old transactions (older than 5 days) to prevent database bloat
      try {
        final pruned = await rust_api.pruneOldTransactions(days: 5);
        if (pruned > BigInt.zero) {
          LoggerService.info(
            'Pruned ${pruned.toInt()} old transactions from database',
          );
        }
      } catch (e) {
        LoggerService.warn('Failed to prune old transactions: $e');
      }

      await _refreshMcpStatus();
      if (_autoEnableMcp && !_isMcpServerRunning) {
        await _toggleMcpServerInternal(enable: true, announce: false);
      }

      final status = rust_api.getProxyStatus();
      _isRecording = status.isRunning;
      _proxyAddress = '${status.bindAddress}:${status.port}';

      // Auto-start recording for convenience
      if (!_isRecording) {
        LoggerService.info('Auto-starting proxy...');
        await toggleRecording();
        // Self-test disabled to avoid example.com traffic in the list
        // _runSelfTest();
      }

      _isInitialized = true;
      LoggerService.info(
        'TrafficState initialized with Rust core v$_rustVersion',
      );

      // Load recent persisted transactions (for sessions where clear-on-quit is off)
      try {
        await _loadInitialPage();
      } catch (e) {
        LoggerService.warn('Failed to load recent transactions: $e');
      }

      // Start polling system proxy status - use longer interval for performance
      _checkSystemProxy();
      _proxyCheckTimer = Timer.periodic(
        const Duration(seconds: 10), // Increased from 3s for better performance
        (_) => _checkSystemProxy(),
      );

      // Subscribe to traffic stream
      _trafficSubscription = rust_api.createTrafficStream().listen(
        (rustTx) {
          // Convert Rust model to Flutter model
          final tx = HttpTransaction.fromRust(rustTx);
          // Use addOrUpdate to handle request/response updates for the same transaction
          addOrUpdateTransaction(tx);
        },
        onError: (e) {
          LoggerService.error('Error in traffic stream: $e');
        },
      );

      notifyListeners();
    } catch (e) {
      LoggerService.error('Failed to initialize TrafficState: $e');
      // Fall back to mock mode
      _isInitialized = false;
      generateMockData();
      notifyListeners();
    }
  }

  void setSortField(TrafficSortField field) {
    if (_sortField == field) {
      _sortAscending = !_sortAscending;
    } else {
      _sortField = field;
      _sortAscending =
          (field == TrafficSortField.timestamp ||
              field == TrafficSortField.requestNumber)
          ? false
          : true;
    }
    notifyListeners();
  }

  int _compareForSort(HttpTransaction a, HttpTransaction b) {
    int compare() {
      switch (_sortField) {
        case TrafficSortField.requestNumber:
          return (_requestNumbers[a.id] ?? 0).compareTo(
            _requestNumbers[b.id] ?? 0,
          );
        case TrafficSortField.timestamp:
          return a.timestamp.compareTo(b.timestamp);
        case TrafficSortField.method:
          return a.method.compareTo(b.method);
        case TrafficSortField.host:
          return a.host.compareTo(b.host);
        case TrafficSortField.path:
          return a.path.compareTo(b.path);
        case TrafficSortField.status:
          return (a.statusCode ?? -1).compareTo(b.statusCode ?? -1);
        case TrafficSortField.duration:
          return (a.duration?.inMilliseconds ?? 0).compareTo(
            b.duration?.inMilliseconds ?? 0,
          );
        case TrafficSortField.size:
          return (a.responseSize ?? 0).compareTo(b.responseSize ?? 0);
      }
    }

    return compare();
  }

  /// Add a new transaction or update existing if ID matches.
  /// Keeps only one row per transaction ID by removing duplicates.
  void addOrUpdateTransaction(HttpTransaction tx) {
    _upsertTransaction(_trimForListView(tx), notify: true, insertAtStart: true);
  }

  void addTransactionsBatch(List<HttpTransaction> transactions) {
    if (transactions.isEmpty) return;
    for (final tx in transactions) {
      _upsertTransaction(
        _trimForListView(tx),
        notify: false,
        insertAtStart: false,
      );
    }
    _transactions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    notifyListeners();
  }

  void _upsertTransaction(
    HttpTransaction tx, {
    required bool notify,
    required bool insertAtStart,
  }) {
    final isSelected = _selectedTransaction?.id == tx.id;
    _transactions.removeWhere((t) => t.id == tx.id);
    _requestNumbers.putIfAbsent(tx.id, () => _nextRequestNumber++);
    if (insertAtStart) {
      _transactions.insert(0, tx);
    } else {
      _transactions.add(tx);
    }
    if (isSelected) {
      _selectedTransaction = tx;
    }
    if (notify) {
      notifyListeners();
    }
  }

  /// Select a transaction (single select - clears multi-select)
  void selectTransaction(HttpTransaction? tx) {
    _selectedTransaction = tx;
    _selectedTransactionIds.clear();
    if (tx != null) {
      _selectedTransactionIds.add(tx.id);
      _lastSelectedIndex = filteredTransactions.indexWhere(
        (t) => t.id == tx.id,
      );
    } else {
      _lastSelectedIndex = null;
    }
    notifyListeners();
  }

  /// Toggle selection of a transaction (Cmd/Ctrl+Click)
  void toggleSelection(HttpTransaction tx) {
    if (_selectedTransactionIds.contains(tx.id)) {
      _selectedTransactionIds.remove(tx.id);
      // Update primary selection if we removed it
      if (_selectedTransaction?.id == tx.id) {
        _selectedTransaction = _selectedTransactionIds.isNotEmpty
            ? filteredTransactions.firstWhere(
                (t) => _selectedTransactionIds.contains(t.id),
                orElse: () => tx,
              )
            : null;
      }
    } else {
      _selectedTransactionIds.add(tx.id);
      _selectedTransaction = tx;
    }
    _lastSelectedIndex = filteredTransactions.indexWhere((t) => t.id == tx.id);
    notifyListeners();
  }

  /// Select a range of transactions (Shift+Click)
  void selectRange(int toIndex) {
    final transactions = filteredTransactions;
    if (transactions.isEmpty) return;

    final fromIndex = _lastSelectedIndex ?? 0;
    final start = fromIndex < toIndex ? fromIndex : toIndex;
    final end = fromIndex < toIndex ? toIndex : fromIndex;

    for (int i = start; i <= end; i++) {
      _selectedTransactionIds.add(transactions[i].id);
    }
    _selectedTransaction = transactions[toIndex];
    _lastSelectedIndex = toIndex;
    notifyListeners();
  }

  /// Select all filtered transactions (Cmd/Ctrl+A)
  void selectAll() {
    final transactions = filteredTransactions;
    _selectedTransactionIds.clear();
    for (final tx in transactions) {
      _selectedTransactionIds.add(tx.id);
    }
    if (transactions.isNotEmpty && _selectedTransaction == null) {
      _selectedTransaction = transactions.first;
    }
    notifyListeners();
  }

  /// Clear all selections
  void clearSelection() {
    _selectedTransactionIds.clear();
    _selectedTransaction = null;
    _lastSelectedIndex = null;
    notifyListeners();
  }

  /// Delete selected transactions
  void deleteSelected() {
    if (_selectedTransactionIds.isEmpty) return;

    // Clear selection first so listeners (detail panel) drop any stale IDs
    final idsToDelete = Set<String>.from(_selectedTransactionIds);
    _selectedTransactionIds.clear();
    _selectedTransaction = null;
    _lastSelectedIndex = null;
    notifyListeners();

    // Remove from main list
    _transactions.removeWhere((tx) => idsToDelete.contains(tx.id));

    notifyListeners();
  }

  /// Delete a specific transaction by ID
  void deleteTransaction(String id) {
    _transactions.removeWhere((tx) => tx.id == id);
    _selectedTransactionIds.remove(id);
    if (_selectedTransaction?.id == id) {
      _selectedTransaction = null;
    }
    notifyListeners();
  }

  /// Update filter
  void setFilter(TransactionFilter filter) {
    _filter = filter;
    notifyListeners();
  }

  /// Toggle recording state - this controls the proxy
  /// Uses optimistic UI: updates state immediately, rolls back on failure
  Future<void> toggleRecording() async {
    final wasRecording = _isRecording;
    final targetState = !wasRecording;

    // Optimistic update - UI responds instantly
    _isRecording = targetState;
    notifyListeners();

    try {
      if (targetState) {
        // Starting proxy
        final config = rust_api.ProxyConfig(
          port: 9090,
          bindAddress: "127.0.0.1",
          enableHttps: true,
          storagePath: _storagePath ?? "./",
        );
        await rust_api.startProxy(config: config);
        // Get the actual port in case the backend fell back to a free one
        final status = rust_api.getProxyStatus();
        final activePort = status.port;
        if (activePort != config.port) {
          LoggerService.warn(
            'Requested port ${config.port} unavailable; using $activePort instead.',
          );
        }
        // Wait briefly until the proxy reports it is running on the chosen port
        await _waitForProxyReady(activePort);
        await SystemProxyService.enableSystemProxy(activePort);
        _proxyAddress = '${config.bindAddress}:$activePort';
      } else {
        // Stopping proxy
        await rust_api.stopProxy();
        await SystemProxyService.disableSystemProxy();
      }
    } catch (e) {
      LoggerService.error('Failed to toggle proxy: $e');
      // Rollback on failure
      _isRecording = wasRecording;
      notifyListeners();
    }
  }

  /// Clear all transactions
  Future<void> clearAll() async {
    _transactions.clear();
    _selectedTransaction = null;
    _selectedTransactionIds.clear();
    _lastSelectedIndex = null;
    notifyListeners();
    try {
      await rust_api.clearAllTransactions();
    } catch (e) {
      LoggerService.error('Failed to clear transactions in backend: $e');
    }
  }

  /// Wait briefly for the proxy to report it is running
  Future<void> _waitForProxyReady(int port) async {
    const maxAttempts = 10;
    const delay = Duration(milliseconds: 100);
    for (var i = 0; i < maxAttempts; i++) {
      try {
        final status = rust_api.getProxyStatus();
        if (status.isRunning && status.port == port) {
          return;
        }
      } catch (_) {
        // ignore and retry
      }
      await Future.delayed(delay);
    }
    LoggerService.warn(
      'Proxy did not report ready within ${(maxAttempts * delay.inMilliseconds)}ms; continuing to enable system proxy.',
    );
  }

  /// Generate mock data for prototyping
  void generateMockData() {
    final random = Random();
    final methods = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'];
    final hosts = [
      'api.github.com',
      'api.stripe.com',
      'api.example.com',
      'cdn.jsdelivr.net',
      'fonts.googleapis.com',
      'analytics.google.com',
    ];
    final paths = [
      '/users',
      '/users/123',
      '/auth/login',
      '/auth/refresh',
      '/orders',
      '/orders/456/items',
      '/products',
      '/products/search',
      '/v1/payments',
      '/v1/webhook',
      '/api/v2/data',
      '/graphql',
    ];
    final statusCodes = [200, 201, 204, 301, 304, 400, 401, 403, 404, 500, 502];

    for (var i = 0; i < 50; i++) {
      final method = methods[random.nextInt(methods.length)];
      final host = hosts[random.nextInt(hosts.length)];
      final path = paths[random.nextInt(paths.length)];
      final statusCode = statusCodes[random.nextInt(statusCodes.length)];
      final duration = Duration(milliseconds: random.nextInt(2000) + 20);
      final size = random.nextInt(50000) + 500;

      final isBreakpointed = i == 3; // One breakpointed request for demo

      final tx = HttpTransaction(
        id: 'tx_${DateTime.now().millisecondsSinceEpoch}_$i',
        timestamp: DateTime.now().subtract(Duration(minutes: i * 2)),
        method: method,
        scheme: 'https',
        host: host,
        path: path,
        query: method == 'GET' && random.nextBool() ? 'page=1&limit=20' : null,
        requestHeaders: {
          'Accept': 'application/json',
          'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...',
          'Content-Type': 'application/json',
          'User-Agent': 'CheddarProxy/1.0',
          'X-Request-ID': 'req_${random.nextInt(99999)}',
        },
        requestBody: method != 'GET'
            ? '''
{
  "id": ${random.nextInt(1000)},
  "name": "Example Item",
  "email": "user@example.com",
  "metadata": {
    "source": "api",
    "version": "2.0"
  }
}'''
            : null,
        requestContentType: 'application/json',
        statusCode: isBreakpointed ? null : statusCode,
        statusMessage: isBreakpointed ? null : _getStatusMessage(statusCode),
        responseHeaders: isBreakpointed
            ? null
            : {
                'Content-Type': 'application/json',
                'X-Request-ID': 'req_${random.nextInt(99999)}',
                'X-Response-Time': '${duration.inMilliseconds}ms',
                'Cache-Control': 'no-cache',
              },
        responseBody: isBreakpointed
            ? null
            : '''
{
  "success": ${statusCode < 400},
  "data": {
    "id": ${random.nextInt(1000)},
    "name": "Response Object",
    "items": [
      {"id": 1, "value": "Item 1"},
      {"id": 2, "value": "Item 2"},
      {"id": 3, "value": "Item 3"}
    ],
    "pagination": {
      "page": 1,
      "limit": 20,
      "total": ${random.nextInt(500)}
    }
  },
  "meta": {
    "requestId": "req_${random.nextInt(99999)}",
    "timestamp": "${DateTime.now().toIso8601String()}"
  }
}''',
        responseContentType: 'application/json',
        responseSize: isBreakpointed ? null : size,
        duration: isBreakpointed ? null : duration,
        state: isBreakpointed
            ? TransactionState.breakpointed
            : TransactionState.completed,
        isBreakpointed: isBreakpointed,
      );

      _transactions.add(tx);
    }
    notifyListeners();
  }

  String _getStatusMessage(int code) {
    switch (code) {
      case 200:
        return 'OK';
      case 201:
        return 'Created';
      case 204:
        return 'No Content';
      case 301:
        return 'Moved Permanently';
      case 304:
        return 'Not Modified';
      case 400:
        return 'Bad Request';
      case 401:
        return 'Unauthorized';
      case 403:
        return 'Forbidden';
      case 404:
        return 'Not Found';
      case 500:
        return 'Internal Server Error';
      case 502:
        return 'Bad Gateway';
      default:
        return 'Unknown';
    }
  }

  HttpTransaction _trimForListView(HttpTransaction tx) {
    String? trimText(String? text) {
      if (text == null || text.length <= _listBodyCacheLimit) return text;
      return text.substring(0, _listBodyCacheLimit);
    }

    Uint8List? trimBytes(Uint8List? bytes) {
      if (bytes == null || bytes.length <= _listBodyCacheLimit) return bytes;
      return bytes.sublist(0, _listBodyCacheLimit);
    }

    return tx.copyWith(
      requestBody: trimText(tx.requestBody),
      responseBody: trimText(tx.responseBody),
      requestBodyBytes: trimBytes(tx.requestBodyBytes),
      responseBodyBytes: trimBytes(tx.responseBodyBytes),
    );
  }

  Future<void> enableSystemProxy() async {
    await SystemProxyService.enableSystemProxy(9090);
    _checkSystemProxy();
  }

  Future<void> disableSystemProxy() async {
    await SystemProxyService.disableSystemProxy();
    _checkSystemProxy();
  }

  /// Export/Open the Root CA certificate for installation
  Future<void> exportRootCa() async {
    if (_storagePath == null) return;
    final pemPath = '$_storagePath/${SystemProxyService.caFileName}';
    final file = File(pemPath);

    if (await file.exists()) {
      LoggerService.info('Opening CA certificate at $pemPath');
      // Using launchUrl with file scheme typically opens the default handler
      final uri = Uri.file(pemPath);
      if (!await launchUrl(uri)) {
        LoggerService.warn('Could not launch $uri');
        // Fallback: reveal in file manager
        if (Platform.isWindows) {
          await Process.run('explorer', [
            '/select,',
            pemPath.replaceAll('/', '\\'),
          ]);
        } else if (Platform.isMacOS) {
          await Process.run('open', ['-R', pemPath]);
        }
      }
    } else {
      LoggerService.warn('CA certificate not found at $pemPath');
    }
  }

  Future<void> _checkSystemProxy() async {
    bool stateChanged = false;

    // Check certificate status - use cache to reduce process spawns
    final now = DateTime.now();
    final shouldCheckCert =
        _lastCertCheck == null ||
        now.difference(_lastCertCheck!) > _certCheckInterval;

    if (shouldCheckCert && await _updateCertificateStatus(force: true)) {
      stateChanged = true;
    }

    // Poll proxy running status from Rust (fast FFI call)
    // Skip in test mode when Rust FFI is not initialized
    int currentPort = 9090;
    if (!_skipRustCalls) {
      try {
        final proxyStatus = rust_api.getProxyStatus();
        final wasRecording = _isRecording;
        _isRecording = proxyStatus.isRunning;
        currentPort = proxyStatus.port;
        _proxyAddress = '${proxyStatus.bindAddress}:$currentPort';

        if (wasRecording != _isRecording) {
          LoggerService.info(
            'Proxy status changed: ${_isRecording ? "running" : "stopped"}',
          );
          // Auto-update system proxy state when Rust status changes
          if (_isRecording) {
            await SystemProxyService.enableSystemProxy(currentPort);
          } else {
            await SystemProxyService.disableSystemProxy();
          }
          stateChanged = true;
        }
      } catch (e) {
        LoggerService.error('Failed to poll proxy status: $e');
      }
    }

    if (!_isRecording) {
      if (_isSystemProxyEnabled) {
        _isSystemProxyEnabled = false;
        stateChanged = true;
      }
    } else {
      // Only check system proxy config if recording (avoid process spawn when not needed)
      final isConfigured = await SystemProxyService.isProxyConfigured(
        currentPort,
      );
      if (isConfigured != _isSystemProxyEnabled) {
        _isSystemProxyEnabled = isConfigured;
        if (!isConfigured) {
          LoggerService.info('Enforcing system proxy on port $currentPort...');
          await SystemProxyService.enableSystemProxy(currentPort);
          _isSystemProxyEnabled = true;
        }
        stateChanged = true;
      }
    }

    // Only notify once if anything changed (reduces UI rebuilds)
    if (stateChanged) {
      notifyListeners();
    }
  }

  Future<int> exportHarToPath({
    required String outputPath,
    bool filteredOnly = false,
  }) async {
    final items = filteredOnly ? filteredTransactions : transactions;
    if (items.isEmpty) {
      throw StateError('No traffic to export');
    }
    final harMap = HarUtils.toHar(items);
    final encoder = const JsonEncoder.withIndent('  ');
    final json = encoder.convert(harMap);
    final file = File(outputPath);
    await file.writeAsString(json);
    LoggerService.info('Exported ${items.length} transactions to $outputPath');
    return items.length;
  }

  /// Export only selected transactions to HAR file
  Future<int> exportSelectedHarToPath({required String outputPath}) async {
    final items = filteredTransactions
        .where((tx) => _selectedTransactionIds.contains(tx.id))
        .toList();
    if (items.isEmpty) {
      throw StateError('No selected transactions to export');
    }
    final harMap = HarUtils.toHar(items);
    final encoder = const JsonEncoder.withIndent('  ');
    final json = encoder.convert(harMap);
    final file = File(outputPath);
    await file.writeAsString(json);
    LoggerService.info(
      'Exported ${items.length} selected transactions to $outputPath',
    );
    return items.length;
  }

  Future<int> importHarFromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('HAR file not found');
    }
    try {
      final contents = await file.readAsString();
      final decoded = jsonDecode(contents);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid HAR structure');
      }
      final imported = HarUtils.fromHar(decoded);
      addTransactionsBatch(imported);
      LoggerService.info('Imported ${imported.length} transactions from $path');
      return imported.length;
    } on FormatException catch (e) {
      LoggerService.error('Failed to parse HAR: $e');
      rethrow;
    } catch (e) {
      LoggerService.error('Failed to import HAR: $e');
      rethrow;
    }
  }

  Future<void> toggleMcpServer({bool? enable}) async {
    await _toggleMcpServerInternal(enable: enable, announce: true);
  }

  Future<void> refreshMcpStatus() async {
    await _refreshMcpStatus();
    notifyListeners();
  }

  Future<void> refreshCertificateStatusNow() async {
    final changed = await _updateCertificateStatus(force: true);
    if (changed) {
      notifyListeners();
    }
  }

  Future<void> setAutoEnableMcp(bool value) async {
    if (_autoEnableMcp == value) return;
    _autoEnableMcp = value;
    await _savePreferences();
    notifyListeners();
    if (value && !_isMcpServerRunning) {
      await _toggleMcpServerInternal(enable: true, announce: true);
    }
  }

  Future<void> setMcpAllowWrites(bool value) async {
    _mcpAllowWrites = value;
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setMcpRequireApproval(bool value) async {
    _mcpRequireApproval = value;
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setClearOnQuit(bool value) async {
    _clearOnQuit = value;
    await _savePreferences();
    notifyListeners();
  }

  Future<bool> _updateCertificateStatus({bool force = false}) async {
    if (_storagePath == null) return false;
    final now = DateTime.now();
    if (!force &&
        _lastCertCheck != null &&
        now.difference(_lastCertCheck!) <= _certCheckInterval) {
      return false;
    }
    _lastCertCheck = now;
    final certStatus = await SystemProxyService.getCertificateStatus(
      _storagePath,
    );
    bool changed = false;
    if (certStatus != _certStatus) {
      _certStatus = certStatus;
      changed = true;
    }
    if (!_hasCertCheckCompleted) {
      _hasCertCheckCompleted = true;
      changed = true;
    }
    return changed;
  }

  Future<void> _toggleMcpServerInternal({
    bool? enable,
    required bool announce,
  }) async {
    if (_storagePath == null || _isMcpToggleInProgress) return;

    final wasRunning = _isMcpServerRunning;
    final targetState = enable ?? !wasRunning;

    LoggerService.info(
      '[MCP] Toggle requested -> ${targetState ? 'enable' : 'disable'} (storage: ${_storagePath ?? '<unset>'})',
    );

    // Optimistic update - UI responds instantly
    _isMcpServerRunning = targetState;
    _isMcpToggleInProgress = true;
    notifyListeners();

    try {
      final status = targetState
          ? await rust_api.enableMcpServer(
              storagePath: _storagePath!,
              autoStartProxy: false,
              allowWrites: _mcpAllowWrites,
              requireApproval: _mcpRequireApproval,
            )
          : await rust_api.disableMcpServer();
      _applyMcpStatus(status);
      LoggerService.info(
        '[MCP] Toggle result -> running=${status.isRunning} socket=${status.socketPath} impl=${status.implementation}',
      );
      if (announce) {
        LoggerService.info(
          targetState
              ? 'MCP server enabled at ${status.socketPath ?? '<unknown>'}'
              : 'MCP server disabled',
        );
      }
    } catch (e) {
      _mcpLastError = e.toString();
      LoggerService.error('Failed to toggle MCP server: $e');
      // Rollback on failure
      _isMcpServerRunning = wasRunning;
    } finally {
      _isMcpToggleInProgress = false;
      notifyListeners();
    }
  }

  Future<void> _refreshMcpStatus() async {
    if (_storagePath == null) return;
    try {
      final status = await rust_api.getMcpServerStatus();
      _applyMcpStatus(status);
    } catch (e) {
      _mcpLastError = e.toString();
      LoggerService.error('Failed to fetch MCP status: $e');
    }
  }

  Future<void> loadMcpToken({bool regenerate = false}) async {
    if (_storagePath == null) return;
    if (_isMcpTokenLoading) return;
    _isMcpTokenLoading = true;
    _mcpTokenError = null;
    notifyListeners();
    try {
      final token = await rust_api.getMcpAuthToken(
        storagePath: _storagePath!,
        regenerate: regenerate,
      );
      _mcpToken = token;
    } catch (e) {
      _mcpTokenError = e.toString();
      LoggerService.error('Failed to load MCP token: $e');
    } finally {
      _isMcpTokenLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadPreferences() async {
    final path = _settingsFilePath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) {
      _autoEnableMcp = false;
      _mcpAllowWrites = false;
      _mcpRequireApproval = true;
      _clearOnQuit = false;
      return;
    }
    try {
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _autoEnableMcp = decoded['auto_enable_mcp'] == true;
      _mcpAllowWrites = decoded['mcp_allow_writes'] == true;
      _mcpRequireApproval = decoded.containsKey('mcp_require_approval')
          ? decoded['mcp_require_approval'] != false
          : true;
      _clearOnQuit = decoded['clear_on_quit'] == true;
    } catch (e) {
      LoggerService.warn('Failed to read MCP settings: $e');
      _autoEnableMcp = false;
      _mcpAllowWrites = false;
      _mcpRequireApproval = true;
      _clearOnQuit = false;
    }
  }

  Future<void> _notifyHostStoragePath() async {
    if (!Platform.isMacOS || _storagePath == null) return;
    const channel = MethodChannel('com.cheddarproxy/platform');
    try {
      await channel.invokeMethod('setStoragePath', {'path': _storagePath});
    } catch (e) {
      LoggerService.warn('Failed to send storage path to host: $e');
    }
  }

  Future<void> _savePreferences() async {
    final path = _settingsFilePath;
    if (path == null) return;
    final file = File(path);
    try {
      await file.writeAsString(
        jsonEncode({
          'auto_enable_mcp': _autoEnableMcp,
          'mcp_allow_writes': _mcpAllowWrites,
          'mcp_require_approval': _mcpRequireApproval,
          'clear_on_quit': _clearOnQuit,
        }),
      );
    } catch (e) {
      LoggerService.warn('Failed to persist MCP settings: $e');
    }
  }

  void _applyMcpStatus(rust_api.McpServerStatus status) {
    _isMcpServerRunning = status.isRunning;
    _mcpSocketPath = status.socketPath;
    _mcpLastError = status.lastError;
    _mcpAllowWrites = status.allowWrites;
    _mcpRequireApproval = status.requireApproval;
  }

  String? get _settingsFilePath {
    final base = _storagePath;
    if (base == null) return null;
    return '$base/$_mcpSettingsFile';
  }

  @visibleForTesting
  void setStoragePathForTest(String path) {
    _storagePath = path;
  }

  @visibleForTesting
  void setRecordingStateForTest(bool value) {
    _isRecording = value;
  }

  @visibleForTesting
  Future<void> runProxyStatusCheckForTest() async {
    await _checkSystemProxy();
  }

  @visibleForTesting
  void setSkipRustCallsForTest(bool value) {
    _skipRustCalls = value;
  }

  @visibleForTesting
  void resetCertCacheForTest() {
    _lastCertCheck = null;
  }

  /// Load the first page of persisted transactions
  Future<void> _loadInitialPage() async {
    const int pageSize = 200;
    final recentRust = await rust_api.listRecentTransactions(limit: pageSize);
    if (recentRust.isEmpty) return;
    final recent = recentRust
        .map((r) => HttpTransaction.fromRust(r))
        .toList(growable: false);
    addTransactionsBatch(recent);
    // Track the oldest timestamp for pagination
    _oldestTimestampMs = recent
        .map((tx) => tx.timestamp.millisecondsSinceEpoch)
        .reduce((a, b) => a < b ? a : b);
    LoggerService.info('Loaded ${recent.length} recent transactions');
  }

  int? _oldestTimestampMs;

  /// Load older transactions (pagination)
  Future<void> loadOlderTransactions({int pageSize = 200}) async {
    if (_oldestTimestampMs == null) return;
    try {
      final olderRust = await rust_api.listTransactionsPage(
        beforeStartedAtMs: _oldestTimestampMs,
        limit: pageSize,
      );
      if (olderRust.isEmpty) return;
      final older = olderRust
          .map((r) => HttpTransaction.fromRust(r))
          .toList(growable: false);
      addTransactionsBatch(older);
      final oldest = older
          .map((tx) => tx.timestamp.millisecondsSinceEpoch)
          .reduce((a, b) => a < b ? a : b);
      _oldestTimestampMs = oldest;
      LoggerService.info('Loaded ${older.length} older transactions');
    } catch (e) {
      LoggerService.warn('Failed to load older transactions: $e');
    }
  }
}
