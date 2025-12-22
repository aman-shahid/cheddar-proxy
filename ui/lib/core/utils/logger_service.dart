import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Centralized logging service for Cheddar Proxy
/// - Debug mode: logs to console via debugPrint
/// - Release mode: logs to file
class LoggerService {
  static LoggerService? _instance;
  static IOSink? _logFile;
  static bool _initialized = false;

  LoggerService._();

  static LoggerService get instance {
    _instance ??= LoggerService._();
    return _instance!;
  }

  /// Initialize the logger (call once at app startup)
  static Future<void> init() async {
    if (_initialized) return;

    if (kReleaseMode) {
      try {
        final appSupport = await getApplicationSupportDirectory();
        final logsDir = Directory('${appSupport.path}/logs');
        if (!await logsDir.exists()) {
          await logsDir.create(recursive: true);
        }
        await _purgeOldLogs(logsDir, const Duration(days: 5));

        final date = DateTime.now().toIso8601String().substring(0, 10);
        final logFile = File('${logsDir.path}/cheddar_proxy_ui_$date.log');
        _logFile = logFile.openWrite(mode: FileMode.append);

        _log('info', 'Logger initialized - writing to ${logFile.path}');
      } catch (e) {
        // Fall back to console if file logging fails
        debugPrint('Failed to initialize file logger: $e');
      }
    }

    _initialized = true;
  }

  /// Log an info message
  static void info(String message) => _log('INFO', message);

  /// Log a warning message
  static void warn(String message) => _log('WARN', message);

  /// Log an error message
  static void error(String message) => _log('ERROR', message);

  /// Log a debug message (only in debug mode)
  static void debug(String message) {
    if (kDebugMode) {
      _log('DEBUG', message);
    }
  }

  static Future<void> _purgeOldLogs(Directory logsDir, Duration maxAge) async {
    try {
      final now = DateTime.now();
      await for (final entity in logsDir.list()) {
        if (entity is File && entity.path.endsWith('.log')) {
          final stat = await entity.stat();
          final age = now.difference(stat.modified);
          if (age > maxAge) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to purge old logs: $e');
    }
  }

  /// Core logging method
  static void _log(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final formatted = '[$timestamp] [$level] $message';

    if (kReleaseMode && _logFile != null) {
      // Release mode: write to file
      _logFile!.writeln(formatted);
    } else {
      // Debug mode: write to console
      debugPrint(formatted);
    }
  }

  /// Flush and close the log file (call on app shutdown)
  static Future<void> close() async {
    if (_logFile != null) {
      await _logFile!.flush();
      await _logFile!.close();
      _logFile = null;
    }
  }
}
