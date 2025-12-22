import 'dart:convert';

import 'package:cheddarproxy/widgets/settings_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MCP config snippet', () {
    test('emits Unix socket config with stdio bridge args', () {
      final jsonString = buildMcpConfigJson(
        isWindows: false,
        socketPath: '/tmp/custom.sock',
        authToken: 'TOKEN',
        bridgeCmd: 'bridge-bin',
      );

      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      final stdio = servers['cheddarproxy-stdio'] as Map<String, dynamic>;
      final socket = servers['cheddarproxy-socket'] as Map<String, dynamic>;

      expect(stdio['command'], 'bridge-bin');
      expect(stdio['args'], ['--socket', '/tmp/custom.sock']);
      expect(socket['transport']['type'], 'unix');
      expect(socket['transport']['path'], '/tmp/custom.sock');
      expect(stdio['auth']['token'], 'TOKEN');
    });

    test('emits Windows TCP config and stdio bridge args', () {
      final jsonString = buildMcpConfigJson(
        isWindows: true,
        socketPath: 'tcp://127.0.0.1:5555',
        authToken: 'WIN_TOKEN',
        bridgeCmd: 'bridge.exe',
      );

      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
      final servers = decoded['mcpServers'] as Map<String, dynamic>;
      final stdio = servers['cheddarproxy-stdio'] as Map<String, dynamic>;
      final tcp = servers['cheddarproxy-tcp'] as Map<String, dynamic>;

      expect(stdio['command'], 'bridge.exe');
      expect(stdio['args'], ['--tcp', '127.0.0.1:5555']);
      expect(stdio['auth']['token'], 'WIN_TOKEN');

      expect(tcp['transport']['type'], 'tcp');
      expect(tcp['transport']['host'], '127.0.0.1');
      expect(tcp['transport']['port'], 5555);
      expect(tcp['auth']['token'], 'WIN_TOKEN');
    });
  });
}
