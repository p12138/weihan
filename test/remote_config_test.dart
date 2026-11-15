// 远程配置模型：解析门禁、字段钳制、密钥白名单、缓存不含密钥。
// 纯 Dart 逻辑（借 flutter_test 的 group/test/expect，不 pump 任何 widget）。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/remote_config.dart';

Map<String, Object?> _base() => <String, Object?>{
      'schema': 1,
      'configVersion': 7,
      'publishedAt': '2026-11-15T10:00:00Z',
      'segmentation': <String, Object?>{
        'silenceMs': 900,
        'maxDraftsPerSentence': 2,
        'speechThreshold': 0.2,
      },
      'interpreter': <String, Object?>{
        'pretranslate': false,
        'rotateAfterMs': 50000,
      },
      'features': <String, Object?>{'continuousMode': false},
      'prompts': <String, Object?>{'systemPrompt': '口语化'},
      'glossary': <String, Object?>{'艾德莱斯': 'ئەتلەس'},
      'strings': <String, Object?>{'configSyncLabel': '同步'},
    };

String _encode(Map<String, Object?> map) => jsonEncode(map);

void main() {
  group('RemoteConfig.parse 门禁', () {
    test('非 JSON 对象抛 FormatException', () {
      expect(() => RemoteConfig.parse('[]'), throwsFormatException);
      expect(() => RemoteConfig.parse('null'), throwsFormatException);
      expect(() => RemoteConfig.parse('42'), throwsFormatException);
      expect(() => RemoteConfig.parse('not-json'), throwsFormatException);
    });

    test('缺 schema 拒绝', () {
      final Map<String, Object?> noSchema = _base()..remove('schema');
      expect(() => RemoteConfig.parse(_encode(noSchema)), throwsFormatException);
    });

    test('schema 不匹配时明确只支持 1', () {
      final Map<String, Object?> badSchema = _base()..['schema'] = 2;
      expect(
        () => RemoteConfig.parse(_encode(badSchema)),
        throwsA(isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('只支持 1'),
        )),
      );
    });
  });

  group('RemoteConfig.parse 字段', () {
    test('解析全部 Tier A 字段', () {
      final RemoteConfig cfg = RemoteConfig.parse(_encode(_base()));
      expect(cfg.configVersion, 7);
      expect(cfg.publishedAt, isNotNull);
      expect(cfg.segmentation.silenceMs, 900);
      expect(cfg.segmentation.maxDraftsPerSentence, 2);
      expect(cfg.segmentation.speechThreshold, 0.2);
      expect(cfg.interpreter.pretranslate, isFalse);
      expect(cfg.interpreter.rotateAfterMs, 50000);
      expect(cfg.features['continuousMode'], isFalse);
      expect(cfg.systemPrompt, '口语化');
      expect(cfg.glossary['艾德莱斯'], 'ئەتلەس');
      expect(cfg.strings['configSyncLabel'], '同步');
    });

    test('未知 section / 字段忽略；空串与非法 bool 丢弃', () {
      final Map<String, Object?> m = _base()
        ..['unknownSection'] = <String, Object?>{'x': 1}
        ..['strings'] = <String, Object?>{'k': '   '}
        ..['features'] = <String, Object?>{'b': 'notbool', 'ok': true};
      final RemoteConfig cfg = RemoteConfig.parse(_encode(m));
      expect(cfg.strings, isEmpty);
      expect(cfg.features, <String, bool>{'ok': true});
    });

    test('数值越界钳到边界而非丢整份配置', () {
      final Map<String, Object?> m = <String, Object?>{
        'schema': 1,
        'segmentation': <String, Object?>{
          'silenceMs': 999999,
          'maxDraftsPerSentence': 99,
          'speechThreshold': 5.0,
        },
      };
      final RemoteConfig cfg = RemoteConfig.parse(_encode(m));
      expect(cfg.segmentation.silenceMs, 5000);
      expect(cfg.segmentation.maxDraftsPerSentence, 5);
      expect(cfg.segmentation.speechThreshold, 1.0);
    });

    test('数值也能吃字符串形式', () {
      final Map<String, Object?> m = <String, Object?>{
        'schema': 1,
        'segmentation': <String, Object?>{'silenceMs': '850'},
        'interpreter': <String, Object?>{'pretranslate': 'false'},
      };
      final RemoteConfig cfg = RemoteConfig.parse(_encode(m));
      expect(cfg.segmentation.silenceMs, 850);
      expect(cfg.interpreter.pretranslate, isFalse);
    });

    test('非法 provider 被忽略，合法 provider 保留', () {
      final Map<String, Object?> bad = <String, Object?>{
        'schema': 1,
        'translation': <String, Object?>{'provider': 'evil'},
      };
      expect(RemoteConfig.parse(_encode(bad)).translation.provider, isNull);
      final Map<String, Object?> good = <String, Object?>{
        'schema': 1,
        'translation': <String, Object?>{'provider': 'azure'},
      };
      expect(RemoteConfig.parse(_encode(good)).translation.provider, 'azure');
    });
  });

  group('密钥', () {
    test('只认白名单键；空值 / 未知键丢弃', () {
      final Map<String, Object?> m = <String, Object?>{
        'schema': 1,
        'secrets': <String, Object?>{
          'translation.appId': 'A',
          'translation.key': 'B',
          'speech.apiSecret': 'C',
          'unknown.key': 'X',
          'speech.appId': '   ',
        },
      };
      final RemoteConfig cfg = RemoteConfig.parse(_encode(m));
      expect(cfg.secrets, <String, String>{
        'translation.appId': 'A',
        'translation.key': 'B',
        'speech.apiSecret': 'C',
      });
    });

    test('toCacheJson 绝不含 secrets，round-trip 后密钥为空', () {
      final Map<String, Object?> m = <String, Object?>{
        'schema': 1,
        'configVersion': 3,
        'secrets': <String, Object?>{'translation.key': 'SUPER_SECRET'},
        'segmentation': <String, Object?>{'silenceMs': 800},
      };
      final RemoteConfig cfg = RemoteConfig.parse(_encode(m));
      final String cache = cfg.toCacheJson();
      expect(cache, isNot(contains('SUPER_SECRET')));
      expect(cache, isNot(contains('secrets')));
      expect(cache, contains('silenceMs'));

      final RemoteConfig again = RemoteConfig.parse(cache);
      expect(again.secrets, isEmpty);
      expect(again.segmentation.silenceMs, 800);
      expect(again.configVersion, 3);
    });
  });

  test('empty 全字段沿用、toString 不泄露明细', () {
    const RemoteConfig cfg = RemoteConfig.empty;
    expect(cfg.configVersion, 0);
    expect(cfg.secrets, isEmpty);
    expect(cfg.translation.isEmpty, isTrue);
    expect(cfg.asr.isEmpty, isTrue);
    expect(cfg.interpreter.isEmpty, isTrue);
    expect(cfg.toString(), isNot(contains('key')));
  });
}
