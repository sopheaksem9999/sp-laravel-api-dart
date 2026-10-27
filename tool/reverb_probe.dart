import 'dart:async';
import 'dart:io';
import 'package:sp_laravel_api/sp_laravel_api.dart';

void main(List<String> args) async {
  final options = _parseArgs(args);

  final host = options['host'] ?? '127.0.0.1';
  final port = int.tryParse(options['port'] ?? '') ?? 8080;
  final appKey = options['key'] ?? 'testappkey';
  final apiUrl = Uri.parse(
    options['api-url'] ?? 'http://127.0.0.1:8000/api/v1',
  );
  final token = options['token'] ?? '';
  final channel = options['channel'] ?? 'private-tenant.10';
  final useTls = options.containsKey('tls') && options['tls'] == 'true';
  final timeoutSeconds = int.tryParse(options['timeout'] ?? '') ?? 30;

  final maskedToken = token.length > 6
      ? '${token.substring(0, 3)}...${token.substring(token.length - 3)}'
      : (token.isEmpty ? '<none>' : '***');

  stdout.writeln('=== Realtime Diagnostic Probe ===');
  stdout.writeln('Host: $host:$port (TLS: $useTls)');
  stdout.writeln('App Key: $appKey');
  stdout.writeln('Auth Endpoint: $apiUrl/broadcasting/auth');
  stdout.writeln('Token: $maskedToken');
  stdout.writeln('Channel: $channel');
  stdout.writeln('Timeout: ${timeoutSeconds}s');
  stdout.writeln('Connecting...');

  final driver = Driver.reverb(
    host: host,
    port: port,
    appKey: appKey,
    useTls: useTls,
  );

  final client = SpRealtime(
    apiBaseUrl: apiUrl,
    driver: driver,
    tokenProvider: () async => token,
  );

  client.onDisconnected(() {
    stdout.writeln('[PROBE] Disconnected from server');
  });

  client.onRecovered(() async {
    stdout.writeln('[PROBE] Connection recovered and channels re-authorized');
  });

  try {
    await client.connect().timeout(const Duration(seconds: 10));
    stdout.writeln('[PROBE] Connected. Socket ID: ${client.socketId}');

    final unsub = await client.subscribe(
      channel,
      onEvent: (event) {
        final sanitizedRecord = Map<String, dynamic>.from(event.record);
        sanitizedRecord.remove('password');
        sanitizedRecord.remove('token');
        sanitizedRecord.remove('secret');

        stdout.writeln(
          '[PROBE] Event: table=${event.table} action=${event.action.name} payload=$sanitizedRecord',
        );
      },
    );

    stdout.writeln('[PROBE] Subscribed to $channel. Listening for events...');
    await Future<void>.delayed(Duration(seconds: timeoutSeconds));
    unsub();
  } catch (err) {
    stderr.writeln('[PROBE ERROR] $err');
    exitCode = 1;
  } finally {
    await client.dispose();
    stdout.writeln('[PROBE] Done.');
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final map = <String, String>{};
  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--')) {
      final name = arg.substring(2);
      if (name.contains('=')) {
        final parts = name.split('=');
        map[parts[0]] = parts.sublist(1).join('=');
      } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        map[name] = args[++i];
      } else {
        map[name] = 'true';
      }
    }
  }
  return map;
}
