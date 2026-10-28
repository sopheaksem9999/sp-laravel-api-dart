import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

class FakeRealtimeTransport implements RealtimeTransport {
  final _incomingController = StreamController<String>.broadcast();
  final _doneController = StreamController<void>.broadcast();
  final List<String> sentMessages = [];
  bool isConnected = false;
  int connectCount = 0;
  bool autoConfirm = true;

  @override
  Stream<String> get incoming => _incomingController.stream;

  @override
  Stream<void> get onDone => _doneController.stream;

  @override
  Future<void> connect(Uri uri) async {
    connectCount++;
    isConnected = true;
    // Simulate server connection_established
    Future.microtask(() {
      _incomingController.add(
        jsonEncode({
          'event': 'pusher:connection_established',
          'data': jsonEncode({
            'socket_id': 'socket_test_123.456',
            'activity_timeout': 120,
          }),
        }),
      );
    });
  }

  @override
  void send(String data) {
    sentMessages.add(data);
    // Like a real server, confirm every subscribe frame.
    final frame = PusherFrame.parse(data);
    if (frame.event == 'pusher:subscribe' && autoConfirm) {
      final channel = (frame.data as Map)['channel'];
      Future.microtask(() {
        _incomingController.add(
          jsonEncode({
            'event': 'pusher_internal:subscription_succeeded',
            'channel': channel,
            'data': '{}',
          }),
        );
      });
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    // Like WebSocketTransport: an app-initiated close emits no onDone.
    isConnected = false;
  }

  void simulateServerMessage(String raw) {
    _incomingController.add(raw);
  }

  void simulateDisconnect() {
    isConnected = false;
    _doneController.add(null);
  }
}

void main() {
  group('SpRealtime Client Core', () {
    test(
      'connect is single-flight and awaits connection_established',
      () async {
        final transport = FakeRealtimeTransport();
        final dio = Dio();

        final rt = SpRealtime(
          apiBaseUrl: Uri.parse('https://example.com/api/v1'),
          driver: Driver.reverb(
            host: 'ws.example.com',
            port: 8080,
            appKey: 'k1',
          ),
          tokenProvider: () async => 'test_token',
          transport: transport,
          dio: dio,
        );

        // Concurrent connect calls
        await Future.wait([rt.connect(), rt.connect(), rt.connect()]);

        expect(rt.isConnected, isTrue);
        expect(transport.connectCount, equals(1));
      },
    );

    test(
      'subscribing to private channel authorizes via /broadcasting/auth',
      () async {
        final transport = FakeRealtimeTransport();
        final dio = Dio();
        RequestOptions? recordedAuthOptions;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('/broadcasting/auth')) {
                recordedAuthOptions = options;
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'auth': 'k1:signature_abc_123'},
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: <String, dynamic>{},
                  ),
                );
              }
            },
          ),
        );

        final rt = SpRealtime(
          apiBaseUrl: Uri.parse('https://example.com/api/v1'),
          driver: Driver.reverb(
            host: 'ws.example.com',
            port: 8080,
            appKey: 'k1',
          ),
          tokenProvider: () async => 'bearer_secret_token',
          transport: transport,
          dio: dio,
        );

        await rt.connect();

        final eventsReceived = <RecordEvent>[];
        await rt.subscribe(
          'private-tenant.42',
          onEvent: (event) => eventsReceived.add(event),
        );

        expect(recordedAuthOptions, isNotNull);
        expect(
          recordedAuthOptions!.headers['Authorization'],
          equals('Bearer bearer_secret_token'),
        );
        expect(
          recordedAuthOptions!.data,
          equals({
            'channel_name': 'private-tenant.42',
            'socket_id': 'socket_test_123.456',
          }),
        );

        // Check subscribe frame sent over transport
        final subscribeFrameRaw = transport.sentMessages.last;
        final parsedFrame = PusherFrame.parse(subscribeFrameRaw);
        expect(parsedFrame.event, equals('pusher:subscribe'));
        expect(parsedFrame.data['channel'], equals('private-tenant.42'));
        expect(parsedFrame.data['auth'], equals('k1:signature_abc_123'));

        // Simulate incoming event
        transport.simulateServerMessage(
          jsonEncode({
            'event': 'videos.created',
            'channel': 'private-tenant.42',
            'data': {
              'table': 'videos',
              'action': 'created',
              'record': {'id': 99, 'title': 'Live Video'},
              'tenant_id': '42',
              'timestamp': '2026-10-27T12:00:00Z',
            },
          }),
        );

        await Future<void>.delayed(Duration.zero);
        expect(eventsReceived.length, equals(1));
        expect(eventsReceived.first.record['title'], equals('Live Video'));
      },
    );

    test(
      '401 on /broadcasting/auth calls handleUnauthorized and retries once',
      () async {
        final transport = FakeRealtimeTransport();
        final dio = Dio();
        int authCalls = 0;
        int handleUnauthorizedCalls = 0;
        String currentToken = 'stale_token';

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              authCalls++;
              if (authCalls == 1) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 401,
                      data: {'message': 'Unauthenticated.'},
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'auth': 'k1:refreshed_signature'},
                  ),
                );
              }
            },
          ),
        );

        final rt = SpRealtime(
          apiBaseUrl: Uri.parse('https://example.com/api/v1'),
          driver: Driver.reverb(
            host: 'ws.example.com',
            port: 8080,
            appKey: 'k1',
          ),
          tokenProvider: () async => currentToken,
          auth: ApiAuth(
            headers: () async => {'Authorization': 'Bearer $currentToken'},
            handleUnauthorized: () async {
              handleUnauthorizedCalls++;
              currentToken = 'fresh_token';
              return true;
            },
          ),
          transport: transport,
          dio: dio,
        );

        await rt.connect();
        await rt.subscribe('private-tenant.42', onEvent: (_) {});

        expect(authCalls, equals(2));
        expect(handleUnauthorizedCalls, equals(1));
      },
    );

    test(
      'channel auth transport failures keep the cause and map timeout/network',
      () async {
        for (final entry in {
          DioExceptionType.connectionTimeout: SpApiErrorCode.timeout,
          DioExceptionType.receiveTimeout: SpApiErrorCode.timeout,
          DioExceptionType.connectionError: SpApiErrorCode.network,
        }.entries) {
          final dio = Dio();
          late DioException original;
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                handler.reject(
                  original = DioException(
                    requestOptions: options,
                    type: entry.key,
                    message: 'boom',
                    stackTrace: StackTrace.current,
                  ),
                );
              },
            ),
          );
          final rt = SpRealtime(
            apiBaseUrl: Uri.parse('https://example.com/api/v1'),
            driver: Driver.reverb(
              host: 'ws.example.com',
              port: 8080,
              appKey: 'k1',
            ),
            tokenProvider: () async => 't',
            transport: FakeRealtimeTransport(),
            dio: dio,
          );
          await rt.connect();
          await expectLater(
            rt.subscribe('private-tenant.42', onEvent: (_) {}),
            throwsA(
              isA<SpApiError>()
                  .having((e) => e.code, 'code', entry.value)
                  .having((e) => e.cause, 'cause', isA<DioException>())
                  .having((e) => identical(e.cause, original), 'same', isTrue)
                  .having(
                    (e) => identical(e.stackTrace, original.stackTrace),
                    'stackTrace',
                    isTrue,
                  ),
            ),
            reason: entry.key.name,
          );
        }
      },
    );

    test(
      'removing one subscription does not drop other active listeners on same channel',
      () async {
        final transport = FakeRealtimeTransport();
        final dio = Dio();

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'auth': 'sig'},
              ),
            ),
          ),
        );

        final rt = SpRealtime(
          apiBaseUrl: Uri.parse('https://example.com/api/v1'),
          driver: Driver.reverb(
            host: 'ws.example.com',
            port: 8080,
            appKey: 'k1',
          ),
          tokenProvider: () async => 'token',
          transport: transport,
          dio: dio,
        );

        await rt.connect();

        final listener1Events = <RecordEvent>[];
        final listener2Events = <RecordEvent>[];

        final cancel1 = await rt.subscribe(
          'private-tenant.42',
          onEvent: (e) => listener1Events.add(e),
        );

        final cancel2 = await rt.subscribe(
          'private-tenant.42',
          onEvent: (e) => listener2Events.add(e),
        );

        // Cancel first listener
        cancel1();

        transport.simulateServerMessage(
          jsonEncode({
            'event': 'videos.created',
            'channel': 'private-tenant.42',
            'data': {
              'table': 'videos',
              'action': 'created',
              'record': {'id': 1},
              'timestamp': '2026-10-27T12:00:00Z',
            },
          }),
        );

        await Future<void>.delayed(Duration.zero);
        expect(listener1Events, isEmpty);
        expect(listener2Events.length, equals(1));

        // Cancel second listener -> sends unsubscribe
        cancel2();
        final lastSent = transport.sentMessages.last;
        final frame = PusherFrame.parse(lastSent);
        expect(frame.event, equals('pusher:unsubscribe'));
        expect(frame.data['channel'], equals('private-tenant.42'));
      },
    );

    test(
      'onRecovered fires once after reconnect and confirmation of active private channels',
      () async {
        final transport = FakeRealtimeTransport();
        final dio = Dio();
        int recoveryCallbackCount = 0;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'auth': 'sig'},
              ),
            ),
          ),
        );

        final rt = SpRealtime(
          apiBaseUrl: Uri.parse('https://example.com/api/v1'),
          driver: Driver.reverb(
            host: 'ws.example.com',
            port: 8080,
            appKey: 'k1',
          ),
          tokenProvider: () async => 'token',
          transport: transport,
          dio: dio,
        );

        rt.onRecovered(() async {
          recoveryCallbackCount++;
        });

        await rt.connect();
        await rt.subscribe('private-tenant.42', onEvent: (_) {});

        // Simulate connection drop
        transport.simulateDisconnect();
        await Future<void>.delayed(Duration.zero);
        expect(rt.isConnected, isFalse);

        // Trigger reconnect
        await rt.connect();

        // Simulate subscription confirmed by server
        transport.simulateServerMessage(
          jsonEncode({
            'event': 'pusher_internal:subscription_succeeded',
            'channel': 'private-tenant.42',
            'data': <String, dynamic>{},
          }),
        );

        await Future<void>.delayed(Duration.zero);
        expect(recoveryCallbackCount, equals(1));
      },
    );
  });
}
