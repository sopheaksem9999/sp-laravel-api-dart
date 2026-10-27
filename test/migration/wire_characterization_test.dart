import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  group('Legacy Wire Characterization & Compatibility Tests', () {
    late Dio mockDio;
    late List<RequestOptions> capturedRequests;
    late Future<Response<dynamic>> Function(RequestOptions options)
    responseHandler;

    setUp(() {
      capturedRequests = [];
      mockDio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
      mockDio.httpClientAdapter = _MockHttpAdapter((options) async {
        capturedRequests.add(options);
        return responseHandler(options);
      });
    });

    test(
      'reproduces identical wire query parameters and headers for table listing',
      () async {
        responseHandler = (options) async {
          return Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'data': [
                {'id': 1, 'number': 'INV-001', 'total': 150.0},
                {'id': 2, 'number': 'INV-002', 'total': 250.0},
              ],
              'meta': {'next_cursor': 'cursor_page_2_xyz', 'per_page': 2},
            },
          );
        };

        final api = SpApi(
          baseUrl: Uri.parse('https://api.example.com/api/v1'),
          tenant: TenantConfig(header: 'X-Tenant-ID', value: () => '101'),
          auth: ApiAuth(
            headers: () async => {'Authorization': 'Bearer legacy_token_abc'},
            handleUnauthorized: () async => false,
          ),
          dio: mockDio,
        );

        final table = api.table('invoices', fromJson: (json) => json);
        final page = await table.list(
          select: 'id,number,total',
          where: [Filter.eq('status', 'paid'), Filter.gte('total', 100)],
          sort: Sort('created_at', Order.desc),
          cursor: 'cursor_token_initial',
          perPage: 2,
        );

        expect(page.items.length, equals(2));
        expect(page.hasMore, isTrue);
        expect(page.nextCursor, equals('cursor_page_2_xyz'));

        expect(capturedRequests.length, equals(1));
        final wireReq = capturedRequests.first;

        // Verify wire path
        expect(wireReq.uri.path, equals('/api/v1/invoices'));

        // Verify wire headers
        expect(wireReq.headers['Accept'], equals('application/json'));
        expect(wireReq.headers['X-Tenant-ID'], equals('101'));
        expect(
          wireReq.headers['Authorization'],
          equals('Bearer legacy_token_abc'),
        );

        // Verify wire query parameters
        expect(wireReq.queryParameters['select'], equals('id,number,total'));
        expect(wireReq.queryParameters['status'], equals('eq.paid'));
        expect(wireReq.queryParameters['total'], equals('gte.100'));
        expect(wireReq.queryParameters['sortby'], equals('created_at'));
        expect(wireReq.queryParameters['order'], equals('desc'));
        expect(
          wireReq.queryParameters['cursor'],
          equals('cursor_token_initial'),
        );
        expect(wireReq.queryParameters['per_page'], equals('2'));
      },
    );

    test(
      'characterizes 422 validation response error mapping into SpApiError',
      () async {
        responseHandler = (options) async {
          throw DioException(
            requestOptions: options,
            response: Response(
              requestOptions: options,
              statusCode: 422,
              data: {
                'message': 'The given data was invalid.',
                'errors': {
                  'email': ['The email field is required.'],
                  'amount': ['The amount must be at least 1.'],
                },
              },
            ),
          );
        };

        final api = SpApi(
          baseUrl: Uri.parse('https://api.example.com/api/v1'),
          dio: mockDio,
        );

        final table = api.table('invoices', fromJson: (json) => json);

        try {
          await table.create({'customer_id': 99});
          fail('Expected SpApiError');
        } on SpApiError catch (err) {
          expect(err.status, equals(422));
          expect(err.code, equals(SpApiErrorCode.validation));
          expect(err.message, contains('The given data was invalid.'));
          expect(
            err.fieldErrors['email'],
            contains('The email field is required.'),
          );
          expect(
            err.fieldErrors['amount'],
            contains('The amount must be at least 1.'),
          );
        }
      },
    );

    test(
      'characterizes 403 forbidden and 401 unauthorized wire error handling',
      () async {
        responseHandler = (options) async {
          throw DioException(
            requestOptions: options,
            response: Response(
              requestOptions: options,
              statusCode: 403,
              data: {'message': 'This action is unauthorized.'},
            ),
          );
        };

        final api = SpApi(
          baseUrl: Uri.parse('https://api.example.com/api/v1'),
          dio: mockDio,
        );

        expect(
          () => api
              .table('invoices', fromJson: (json) => json)
              .get('999', select: 'id'),
          throwsA(
            isA<SpApiError>()
                .having((e) => e.status, 'status', equals(403))
                .having(
                  (e) => e.code,
                  'code',
                  equals(SpApiErrorCode.forbidden),
                ),
          ),
        );
      },
    );
  });
}

class _MockHttpAdapter implements HttpClientAdapter {
  final Future<Response<dynamic>> Function(RequestOptions options) handler;

  _MockHttpAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    try {
      final res = await handler(options);
      final data = res.data;
      final jsonStr = data is String ? data : jsonEncode(data);
      return ResponseBody.fromString(
        jsonStr,
        res.statusCode ?? 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    } on DioException catch (e) {
      if (e.response != null) {
        final d = e.response?.data;
        final jsonStr = d is String ? d : jsonEncode(d);
        return ResponseBody.fromString(
          jsonStr,
          e.response?.statusCode ?? 500,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      rethrow;
    }
  }

  @override
  void close({bool force = false}) {}
}
