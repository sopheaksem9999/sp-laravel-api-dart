import 'dart:io';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  test('scaffold exports valid packageVersion', () {
    expect(packageVersion, matches(r'^\d+\.\d+\.\d+(-beta\.\d+)?$'));
  });

  test('pubspec specifies floor Dart 3.8, dio range and no flutter sdk', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains("sdk: '>=3.8.0 <4.0.0'"));
    expect(pubspec, contains('name: sp_laravel_api'));
    expect(pubspec, contains('dio: ">=5.8.0 <6.0.0"'));
    expect(pubspec, contains('web_socket_channel: ^3.0.0'));
    expect(pubspec, isNot(contains('sdk: flutter')));
  });
}
