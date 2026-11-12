import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/update_manifest.dart';

const String _validAndroid = '''
{
  "schema": 1,
  "platform": "android",
  "version": "0.5.0",
  "build": 2,
  "notes": "修复翻译等待",
  "file": "weihan-selfuse-arm64.apk",
  "size": 21000000,
  "sha256": "2ff5eed3a728924725462592a9e052c5df44968f0d96c888079b26e7831eee45",
  "requiresResign": false,
  "publishedAt": "2026-11-13T00:30:00Z"
}
''';

String _androidWith(Map<String, String> overrides) {
  String body = _validAndroid;
  overrides.forEach((String key, String value) {
    body = body.replaceAll(RegExp('"$key": .*'), '"$key": $value,');
  });
  return body;
}

void main() {
  group('UpdateManifest.parse', () {
    test('解析合法清单', () {
      final UpdateManifest manifest = UpdateManifest.parse(_validAndroid);
      expect(manifest.platform, 'android');
      expect(manifest.version, '0.5.0');
      expect(manifest.build, 2);
      expect(manifest.file, 'weihan-selfuse-arm64.apk');
      expect(manifest.size, 21000000);
      expect(manifest.sha256.length, 64);
      expect(manifest.requiresResign, isFalse);
      expect(manifest.notes, '修复翻译等待');
      expect(manifest.publishedAt, isNotNull);
      expect(manifest.sizeLabel, '20.0 MB');
    });

    test('schema 不认识时拒绝，而不是猜', () {
      expect(
        () => UpdateManifest.parse(_androidWith(<String, String>{'schema': '99'})),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('只支持 1'),
          ),
        ),
      );
    });

    test('sha256 不是 64 位十六进制时拒绝', () {
      expect(
        () => UpdateManifest.parse(
          _androidWith(<String, String>{'sha256': '"abc123"'}),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('file 带路径时拒绝，防止清单把文件写到目录外', () {
      expect(
        () => UpdateManifest.parse(
          _androidWith(<String, String>{'file': '"../../evil.apk"'}),
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('不能带路径'),
          ),
        ),
      );
    });

    test('size 为 0 时拒绝', () {
      expect(
        () => UpdateManifest.parse(_androidWith(<String, String>{'size': '0'})),
        throwsA(isA<FormatException>()),
      );
    });

    test('不是 JSON 对象时给出明确错误', () {
      expect(
        () => UpdateManifest.parse('[]'),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('不是 JSON 对象'),
          ),
        ),
      );
    });
  });

  group('版本比较', () {
    test('逐段比较而不是按字符串', () {
      expect(compareAppVersions('0.5.0', '0.4.9'), greaterThan(0));
      expect(compareAppVersions('0.10.0', '0.9.9'), greaterThan(0));
      expect(compareAppVersions('1.0.0', '0.99.99'), greaterThan(0));
      expect(compareAppVersions('0.5.0', '0.5.0'), 0);
    });

    test('支持 v 前缀与 +build', () {
      expect(compareAppVersions('v0.5.0', '0.5.0'), 0);
      expect(compareAppVersions('0.5.0+3', '0.5.0+1'), greaterThan(0));
    });

    test('段数不足按 0 处理', () {
      expect(compareAppVersions('0.5', '0.5.0'), 0);
      expect(compareAppVersions('1', '0.9.9'), greaterThan(0));
    });

    test('isNewerThan 只比版本，不比构建号', () {
      final UpdateManifest manifest =
          UpdateManifest.parse(_validAndroid); // 0.5.0 + 2
      expect(manifest.isNewerThan('0.4.6+1'), isTrue);
      expect(manifest.isNewerThan('0.5.0+1'), isFalse,
          reason: 'TestFlight 每次换 build number，同版本不该反复提示更新');
      expect(manifest.isNewerThan('0.5.1+1'), isFalse);
    });
  });

  test('formatBytes 覆盖三档', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2.0 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
  });
}
