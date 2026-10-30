import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:sp_laravel_api/src/modules/upload_fields.dart';
import 'package:test/test.dart';

void expectUnencodable(void Function() body, [Pattern? message]) {
  try {
    body();
    fail('expected an SpApiError');
  } on SpApiError catch (e) {
    expect(e.code, SpApiErrorCode.unencodableValue);
    expect(e.status, 0);
    if (message != null) expect(e.message, contains(message));
  }
}

void check(UploadFieldOptions o, [UploadStrategy s = UploadStrategy.form]) =>
    checkUploadFields(o, s);

void main() {
  group('checkUploadFields rules', () {
    test('asTemp true with private or public visibility throws', () {
      expectUnencodable(
        () => check(
          const UploadFieldOptions(asTemp: true, visibility: 'private'),
        ),
        'asTemp',
      );
      expectUnencodable(
        () =>
            check(const UploadFieldOptions(asTemp: true, visibility: 'public')),
        'asTemp',
      );
    });

    test('asTemp true alone or with a temp visibility is allowed', () {
      check(const UploadFieldOptions(asTemp: true));
      check(const UploadFieldOptions(asTemp: true, visibility: 'temp_public'));
    });

    test('asTemp false never throws (with temp_private, with public)', () {
      check(
        const UploadFieldOptions(asTemp: false, visibility: 'temp_private'),
      );
      check(const UploadFieldOptions(asTemp: false, visibility: 'public'));
      check(
        const UploadFieldOptions(
          asTemp: false,
          visibility: 'temp_public',
          tempTimeoutMinutes: 10,
        ),
      );
    });

    test('a timeout without a temporary upload throws', () {
      expectUnencodable(
        () => check(const UploadFieldOptions(tempTimeoutMinutes: 30)),
        'temporary',
      );
      expectUnencodable(
        () => check(
          const UploadFieldOptions(
            visibility: 'private',
            tempTimeoutAt: '2026-10-30T10:00:00Z',
          ),
        ),
        'temporary',
      );
      check(const UploadFieldOptions(asTemp: true, tempTimeoutMinutes: 30));
      check(
        const UploadFieldOptions(
          visibility: 'temp_private',
          tempTimeoutMinutes: 30,
        ),
      );
    });

    test('both timeouts throws', () {
      expectUnencodable(
        () => check(
          const UploadFieldOptions(
            asTemp: true,
            tempTimeoutMinutes: 30,
            tempTimeoutAt: '2026-10-30T10:00:00Z',
          ),
        ),
        'tempTimeout',
      );
    });

    test(
      'a timeout that is not a positive integer or an empty string throws',
      () {
        for (final v in [0, -5]) {
          expectUnencodable(
            () =>
                check(UploadFieldOptions(asTemp: true, tempTimeoutMinutes: v)),
            'tempTimeoutMinutes',
          );
        }
        expectUnencodable(
          () =>
              check(const UploadFieldOptions(asTemp: true, tempTimeoutAt: '')),
          'tempTimeoutAt',
        );
        expectUnencodable(
          () =>
              check(const UploadFieldOptions(asTemp: true, tempTimeoutAt: 42)),
          'tempTimeoutAt',
        );
      },
    );

    test('replaceOld true without a record throws', () {
      for (final o in const [
        UploadFieldOptions(replaceOld: true),
        UploadFieldOptions(replaceOld: true, recordType: 'products'),
        UploadFieldOptions(replaceOld: true, recordId: 7),
      ]) {
        expectUnencodable(() => check(o), 'replaceOld');
      }
      check(
        const UploadFieldOptions(
          replaceOld: true,
          recordType: 'products',
          recordId: 7,
        ),
      );
    });

    test('replaceOld false is a no-op', () {
      check(const UploadFieldOptions(replaceOld: false));
      expect(
        sharedFields(const UploadFieldOptions(replaceOld: false)),
        isEmpty,
      );
    });

    test('sizeName with width, height or fit throws', () {
      for (final o in const [
        UploadFieldOptions(sizeName: 'thumb', width: 100),
        UploadFieldOptions(sizeName: 'thumb', height: 100),
        UploadFieldOptions(sizeName: 'thumb', fit: 'crop'),
      ]) {
        expectUnencodable(() => check(o), 'sizeName');
      }
      check(const UploadFieldOptions(sizeName: 'thumb'));
      expectUnencodable(
        () => check(const UploadFieldOptions(sizeName: '')),
        'sizeName',
      );
    });

    test('width and height must be positive integers', () {
      for (final v in [0, -1]) {
        expectUnencodable(() => check(UploadFieldOptions(width: v)), 'width');
        expectUnencodable(() => check(UploadFieldOptions(height: v)), 'height');
      }
      check(const UploadFieldOptions(width: 512, height: 256));
    });

    test('fit must be crop or contain', () {
      expectUnencodable(
        () => check(const UploadFieldOptions(fit: 'stretch')),
        'fit',
      );
      check(const UploadFieldOptions(fit: 'crop'));
      check(const UploadFieldOptions(fit: 'contain'));
    });

    test('direct and multipart reject resize options and asTemp true', () {
      for (final s in [UploadStrategy.direct, UploadStrategy.multipart]) {
        for (final o in const [
          UploadFieldOptions(width: 100),
          UploadFieldOptions(height: 100),
          UploadFieldOptions(fit: 'crop'),
          UploadFieldOptions(sizeName: 'thumb'),
          UploadFieldOptions(asTemp: true),
        ]) {
          expectUnencodable(() => check(o, s));
        }
        check(const UploadFieldOptions(asTemp: false), s);
        check(
          const UploadFieldOptions(
            visibility: 'temp_private',
            tempTimeoutMinutes: 30,
            title: 'x',
          ),
          s,
        );
      }
    });
  });

  group('wire fields', () {
    test('sharedFields uses the backend names and values', () {
      final f = sharedFields(
        UploadFieldOptions(
          replaceOld: true,
          folderId: '12',
          title: 'Logo',
          caption: 'Our logo',
          tempTimeoutMinutes: 30,
        ),
      );
      expect(f, {
        'replace_old': true,
        'folder_id': '12',
        'title': 'Logo',
        'caption': 'Our logo',
        'temp_timeout_minutes': '30',
      });
    });

    test(
      'tempTimeoutAt: a string is sent unchanged, a DateTime as UTC ISO',
      () {
        expect(
          sharedFields(
            const UploadFieldOptions(
              tempTimeoutAt: '2026-10-30T17:00:00+07:00',
            ),
          )['temp_timeout_at'],
          '2026-10-30T17:00:00+07:00',
        );
        expect(
          sharedFields(
            UploadFieldOptions(tempTimeoutAt: DateTime.utc(2026, 10, 30, 10)),
          )['temp_timeout_at'],
          '2026-10-30T10:00:00.000Z',
        );
      },
    );

    test(
      'formOnlyFields uses w, h, fit, size_name and as_temp (only true)',
      () {
        expect(
          formOnlyFields(
            const UploadFieldOptions(
              width: 512,
              height: 256,
              fit: 'crop',
              asTemp: true,
            ),
          ),
          {'w': '512', 'h': '256', 'fit': 'crop', 'as_temp': true},
        );
        expect(formOnlyFields(const UploadFieldOptions(sizeName: 'thumb')), {
          'size_name': 'thumb',
        });
        expect(
          formOnlyFields(const UploadFieldOptions(asTemp: false)),
          isEmpty,
        );
      },
    );
  });
}
