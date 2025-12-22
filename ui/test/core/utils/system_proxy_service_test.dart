import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cheddarproxy/core/utils/system_proxy_service.dart';

ProcessResult _result(int exitCode, {String stdout = '', String stderr = ''}) =>
    ProcessResult(0, exitCode, stdout, stderr);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SystemProxyService.setPlatformOverride(null);
    SystemProxyService.resetProcessRunner();
    SystemProxyService.resetTestOverrides();
  });

  tearDown(() {
    SystemProxyService.setPlatformOverride(null);
    SystemProxyService.resetProcessRunner();
    SystemProxyService.resetTestOverrides();
  });

  test('enableSystemProxy on macOS executes expected commands', () async {
    SystemProxyService.setPlatformOverride(TestPlatform.macos);
    final calls = <List<String>>[];
    SystemProxyService.setProcessRunnerForTesting((command, args) async {
      calls.add([command, ...args]);
      return _result(0);
    });

    final success = await SystemProxyService.enableSystemProxy(9090);

    expect(success, isTrue);
    expect(calls, [
      ['networksetup', '-setwebproxy', 'Wi-Fi', '127.0.0.1', '9090'],
      ['networksetup', '-setwebproxystate', 'Wi-Fi', 'on'],
      ['networksetup', '-setsecurewebproxy', 'Wi-Fi', '127.0.0.1', '9090'],
      ['networksetup', '-setsecurewebproxystate', 'Wi-Fi', 'on'],
    ]);
  });

  test('enableSystemProxy returns false at first failing command', () async {
    SystemProxyService.setPlatformOverride(TestPlatform.macos);
    var callIndex = 0;
    SystemProxyService.setProcessRunnerForTesting((command, args) async {
      callIndex++;
      if (callIndex == 2) {
        return _result(1, stderr: 'boom');
      }
      return _result(0);
    });

    final success = await SystemProxyService.enableSystemProxy(8080);

    expect(success, isFalse);
    expect(callIndex, 2);
  });

  test('isProxyConfigured parses macOS networksetup output', () async {
    SystemProxyService.setPlatformOverride(TestPlatform.macos);
    final stdoutSamples = [
      'Enabled: Yes\nServer: 127.0.0.1\nPort: 9090\n',
      'Enabled: Yes\nServer: 127.0.0.1\nPort: 9090\n',
    ];
    SystemProxyService.setProcessRunnerForTesting((command, args) async {
      return _result(0, stdout: stdoutSamples.removeAt(0));
    });

    final configured = await SystemProxyService.isProxyConfigured(9090);

    expect(configured, isTrue);
    expect(stdoutSamples, isEmpty);
  });

  test(
    'trustAndImportCertificate on macOS uses Swift helper via xcrun',
    () async {
      SystemProxyService.setPlatformOverride(TestPlatform.macos);
      final tempDir = await Directory.systemTemp.createTemp(
        'cheddarproxy_cert',
      );
      final certPath = '${tempDir.path}/${SystemProxyService.caFileName}';
      await File(certPath).writeAsString('-----BEGIN CERTIFICATE-----\nFAKE\n');

      final calls = <List<String>>[];
      SystemProxyService.setProcessRunnerForTesting((command, args) async {
        calls.add([command, ...args]);
        // First call is openssl to get common name, second is xcrun swift
        if (command == '/usr/bin/openssl') {
          return _result(0, stdout: 'subject=CN=Cheddar Proxy CA');
        }
        if (command == 'xcrun') {
          return _result(0); // Swift helper succeeds
        }
        return _result(0);
      });

      final trusted = await SystemProxyService.trustAndImportCertificate(
        certPath,
      );

      expect(trusted, isTrue);
      // Should have called openssl then xcrun swift
      expect(calls.any((c) => c[0] == '/usr/bin/openssl'), isTrue);
      expect(calls.any((c) => c[0] == 'xcrun' && c[1] == 'swift'), isTrue);
    },
  );

  test(
    'enableSystemProxy on Windows sets registry values via PowerShell',
    () async {
      SystemProxyService.setPlatformOverride(TestPlatform.windows);
      final calls = <List<String>>[];
      SystemProxyService.setProcessRunnerForTesting((command, args) async {
        calls.add([command, ...args]);
        return _result(0);
      });

      final success = await SystemProxyService.enableSystemProxy(8888);

      expect(success, isTrue);
      expect(calls.length, greaterThanOrEqualTo(1));
      expect(calls.first.first, 'powershell');
      expect(calls.first[1], '-Command');
      // The command contains ProxyEnable in one of the calls
      expect(calls.any((c) => c.join(' ').contains('ProxyEnable')), isTrue);
    },
  );

  test('isProxyConfigured on Windows succeeds on exit code 0', () async {
    SystemProxyService.setPlatformOverride(TestPlatform.windows);
    SystemProxyService.setProcessRunnerForTesting((command, args) async {
      expect(command, 'powershell');
      expect(args.first, '-Command');
      return _result(0);
    });

    final configured = await SystemProxyService.isProxyConfigured(1234);
    expect(configured, isTrue);
  });

  test(
    'trustAndImportCertificate on Windows invokes certutil with RunAs',
    () async {
      SystemProxyService.setPlatformOverride(TestPlatform.windows);
      final tempDir = await Directory.systemTemp.createTemp('cert_test');
      final certPath = '${tempDir.path}/cheddar_proxy_ca.pem';
      await File(certPath).writeAsString('dummy');

      final calls = <List<String>>[];
      SystemProxyService.setProcessRunnerForTesting((command, args) async {
        calls.add([command, ...args]);
        return _result(0);
      });

      final ok = await SystemProxyService.trustAndImportCertificate(certPath);

      expect(ok, isTrue);
      expect(calls.single.first, 'powershell');
      expect(calls.single[1], '-Command');
      // The full command string should contain certutil and -addstore
      expect(calls.single.join(' '), contains('certutil'));
      expect(calls.single.join(' '), contains('-addstore'));
    },
  );

  test('viewCertificateInKeychain on Windows launches certmgr.msc', () async {
    SystemProxyService.setPlatformOverride(TestPlatform.windows);
    final calls = <List<String>>[];
    SystemProxyService.setProcessRunnerForTesting((command, args) async {
      calls.add([command, ...args]);
      return _result(0);
    });

    final ok = await SystemProxyService.viewCertificateInKeychain();

    expect(ok, isTrue);
    expect(calls.single, ['certmgr.msc']);
  });

  test(
    'enableSystemProxy on Windows issues PowerShell registry commands',
    () async {
      SystemProxyService.setPlatformOverride(TestPlatform.windows);
      final calls = <List<String>>[];
      SystemProxyService.setProcessRunnerForTesting((command, args) async {
        calls.add([command, ...args]);
        // First call checks if already configured (return exit 1 = not configured)
        if (calls.length == 1) {
          return _result(1); // Not already configured
        }
        return _result(0);
      });

      final success = await SystemProxyService.enableSystemProxy(7777);

      expect(success, isTrue);
      // First call is the check, second is the actual set
      expect(calls.length, 2);
      expect(calls[0][0], 'powershell');
      expect(calls[1][0], 'powershell');
      expect(calls[1][1], '-Command');
      expect(calls[1][2], contains('ProxyEnable'));
      expect(calls[1][2], contains('127.0.0.1:7777'));
    },
  );

  test(
    'disableSystemProxy on Windows uses PowerShell registry command',
    () async {
      SystemProxyService.setPlatformOverride(TestPlatform.windows);
      final calls = <List<String>>[];
      SystemProxyService.setProcessRunnerForTesting((command, args) async {
        calls.add([command, ...args]);
        return _result(0);
      });

      final success = await SystemProxyService.disableSystemProxy();

      expect(success, isTrue);
      expect(calls.length, 1);
      expect(calls[0][0], 'powershell');
      expect(calls[0][1], '-Command');
      expect(calls[0][2], contains('ProxyEnable'));
      expect(calls[0][2], contains('Value 0'));
    },
  );

  test('isProxyConfigured on Windows parses netsh output', () async {
    SystemProxyService.setPlatformOverride(TestPlatform.windows);
    SystemProxyService.setProcessRunnerForTesting((command, args) async {
      return _result(0, stdout: 'Proxy Server(s) : 127.0.0.1:8081');
    });

    final configured = await SystemProxyService.isProxyConfigured(8081);

    expect(configured, isTrue);
  });

  test(
    'trustAndImportCertificate on Windows calls certutil via PowerShell',
    () async {
      SystemProxyService.setPlatformOverride(TestPlatform.windows);
      final tempDir = await Directory.systemTemp.createTemp(
        'cheddarproxy_win_cert',
      );
      final certPath = '${tempDir.path}/${SystemProxyService.caFileName}';
      await File(certPath).writeAsString('-----BEGIN CERTIFICATE-----\nFAKE\n');

      List<String>? lastCall;
      SystemProxyService.setProcessRunnerForTesting((command, args) async {
        lastCall = [command, ...args];
        return _result(0);
      });

      final trusted = await SystemProxyService.trustAndImportCertificate(
        certPath,
      );

      expect(trusted, isTrue);
      expect(lastCall?.first, 'powershell');
      expect(lastCall?[1], '-Command');
      expect(lastCall?[2], contains('Start-Process certutil'));
      expect(lastCall?.join(' '), contains(certPath.replaceAll('\\', '\\\\')));
    },
  );
}
