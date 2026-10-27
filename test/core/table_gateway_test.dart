import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

class Video {
  final int id;
  final String title;

  Video({required this.id, required this.title});

  factory Video.fromJson(Map<String, dynamic> json) =>
      Video(id: json['id'] as int, title: json['title'] as String);
}

void main() {
  group('TableGateway CRUD & Pagination', () {
    test(
      'list returns CursorPage with deserialized items and nextCursor',
      () async {
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.path, contains('/videos'));
              expect(options.queryParameters['select'], equals('id,title'));
              expect(options.queryParameters['per_page'], equals('2'));
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'success': true,
                    'data': [
                      {'id': 1, 'title': 'Intro'},
                      {'id': 2, 'title': 'Deep Dive'},
                    ],
                    'meta': {'next_cursor': 'cur_page_2', 'total': 100},
                  },
                ),
              );
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          dio: dio,
        );

        final videos = api.table('videos', fromJson: Video.fromJson);
        final page = await videos.list(select: 'id,title', perPage: 2);

        expect(page.items.length, equals(2));
        expect(page.items[0].title, equals('Intro'));
        expect(page.items[1].title, equals('Deep Dive'));
        expect(page.nextCursor, equals('cur_page_2'));
        expect(page.total, equals(100));
      },
    );

    test('get returns single item and enforces select by default', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, contains('/videos/42'));
            expect(options.queryParameters['select'], equals('id,title'));
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'success': true,
                  'data': {'id': 42, 'title': 'Specific Video'},
                },
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        dio: dio,
      );

      final videos = api.table('videos', fromJson: Video.fromJson);

      // Fails when select is omitted
      expect(
        () => videos.get(42),
        throwsA(
          isA<SpApiError>().having(
            (e) => e.code,
            'code',
            SpApiErrorCode.unencodableValue,
          ),
        ),
      );

      final video = await videos.get(42, select: 'id,title');
      expect(video.id, equals(42));
      expect(video.title, equals('Specific Video'));
    });

    test(
      'create, update, remove, and restore execute appropriate endpoints',
      () async {
        final dio = Dio();
        final recordedMethods = <String>[];

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              recordedMethods.add(options.method);
              if (options.method == 'POST' &&
                  options.path.endsWith('/restore')) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'success': true,
                      'data': {'restored': 1},
                    },
                  ),
                );
              } else if (options.method == 'DELETE') {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'success': true,
                      'data': {'deleted': true},
                    },
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'success': true,
                      'data': {'id': 10, 'title': 'Mutated Title'},
                    },
                  ),
                );
              }
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          dio: dio,
        );

        final videos = api.table('videos', fromJson: Video.fromJson);

        final created = await videos.create({'title': 'New'});
        expect(created.id, equals(10));

        final updated = await videos.update(10, {'title': 'Updated'});
        expect(updated.title, equals('Mutated Title'));

        final deleted = await videos.remove(10);
        expect(deleted, isTrue);

        final restoredCount = await videos.restore(10);
        expect(restoredCount, equals(1));

        expect(recordedMethods, equals(['POST', 'PUT', 'DELETE', 'POST']));
      },
    );

    test('iterate yields items across multiple pages as a Stream', () async {
      final dio = Dio();
      int pageCount = 0;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            pageCount++;
            if (pageCount == 1) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'success': true,
                    'data': [
                      {'id': 1, 'title': 'Item 1'},
                      {'id': 2, 'title': 'Item 2'},
                    ],
                    'meta': {'next_cursor': 'cur_2'},
                  },
                ),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'success': true,
                    'data': [
                      {'id': 3, 'title': 'Item 3'},
                    ],
                    'meta': {'next_cursor': null},
                  },
                ),
              );
            }
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        dio: dio,
      );

      final videos = api.table('videos', fromJson: Video.fromJson);
      final stream = videos.iterate(select: 'id,title', perPage: 2);
      final collected = await stream.toList();

      expect(collected.length, equals(3));
      expect(collected.map((v) => v.id), equals([1, 2, 3]));
      expect(pageCount, equals(2));
    });

    test('fetchFirst sends cursor: null and fetches first page', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.queryParameters['cursor'], isNull);
            expect(options.queryParameters['per_page'], equals('1'));
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'success': true,
                  'data': [
                    {'id': 1, 'title': 'First'},
                  ],
                  'meta': {'next_cursor': 'cur_2'},
                },
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        dio: dio,
      );
      final videos = api.table('videos', fromJson: Video.fromJson);
      final page = await videos.fetchFirst(select: 'id,title', perPage: 1);

      expect(page.items.length, equals(1));
      expect(page.items[0].id, equals(1));
      expect(page.nextCursor, equals('cur_2'));
    });

    test(
      'fetchLast inverts sort direction and restores items to canonical order',
      () async {
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              // Verifies sort direction was inverted to desc
              expect(options.queryParameters['sortby'], equals('title'));
              expect(options.queryParameters['order'], equals('desc'));
              expect(options.queryParameters['cursor'], isNull);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'success': true,
                    'data': [
                      {'id': 3, 'title': 'Zeta'},
                      {'id': 2, 'title': 'Beta'},
                      {'id': 1, 'title': 'Alpha'},
                    ],
                    'meta': {'next_cursor': 'before_alpha_cursor', 'total': 3},
                  },
                ),
              );
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          dio: dio,
        );
        final videos = api.table('videos', fromJson: Video.fromJson);
        final page = await videos.fetchLast(
          select: 'id,title',
          sort: const Sort('title', Order.asc),
          perPage: 3,
        );

        // Re-ordered to canonical chronological order: Alpha, Beta, Zeta
        expect(
          page.items.map((v) => v.title),
          equals(['Alpha', 'Beta', 'Zeta']),
        );
        expect(page.nextCursor, isNull);
        expect(page.prevCursor, equals('before_alpha_cursor'));
        expect(page.total, equals(3));
      },
    );

    test(
      'fetchNext and fetchPrev thread cursors and return null on absent cursor',
      () async {
        final dio = Dio();
        String? lastCursorParam;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              lastCursorParam = options.queryParameters['cursor'] as String?;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'success': true,
                    'data': [
                      {'id': 2, 'title': 'Item 2'},
                    ],
                    'meta': {'next_cursor': 'cur_3', 'prev_cursor': 'cur_1'},
                  },
                ),
              );
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          dio: dio,
        );
        final videos = api.table('videos', fromJson: Video.fromJson);

        final current = CursorPage<Video>(
          items: [Video(id: 1, title: 'Item 1')],
          nextCursor: 'cur_2',
          prevCursor: 'cur_0',
        );

        final nextPage = await videos.fetchNext(current, select: 'id,title');
        expect(lastCursorParam, equals('cur_2'));
        expect(nextPage, isNotNull);

        final prevPage = await videos.fetchPrev(current, select: 'id,title');
        expect(lastCursorParam, equals('cur_0'));
        expect(prevPage, isNotNull);

        const emptyPage = CursorPage<Video>(items: []);
        expect(await videos.fetchNext(emptyPage), isNull);
        expect(await videos.fetchPrev(emptyPage), isNull);
      },
    );

    test(
      'cursorPagination controller manages pagination preserving query state',
      () async {
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'success': true,
                    'data': [
                      {'id': 1, 'title': 'Item 1'},
                    ],
                    'meta': {'next_cursor': 'cur_2'},
                  },
                ),
              );
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          dio: dio,
        );
        final videos = api.table('videos', fromJson: Video.fromJson);
        final pagination = videos.cursorPagination(
          select: 'id,title',
          perPage: 1,
        );

        final first = await pagination.firstPage();
        expect(first.items.length, equals(1));
        expect(first.nextCursor, equals('cur_2'));
      },
    );
  });
}
