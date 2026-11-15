// 远程配置「生效层」：安全白名单合并、URL 校验、密钥保护、state 与断句器构造。
// 全部通过注入全新的 TranslationConfig / SpeechConfig / RemoteConfigState 隔离，
// 不污染进程级单例。

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/interpreter_segmenter.dart';
import 'package:uyghur_interpreter/remote_config.dart';
import 'package:uyghur_interpreter/remote_config_state.dart';
import 'package:uyghur_interpreter/speech_config.dart';
import 'package:uyghur_interpreter/translation_config.dart';

void main() {
  group('applyRemoteConfig 零信任默认', () {
    test('Tier A 全部应用，敏感项全部跳过', () {
      final TranslationConfig t = TranslationConfig();
      final SpeechConfig s = SpeechConfig();
      final RemoteConfigState st = RemoteConfigState();
      const RemoteConfig cfg = RemoteConfig(
        configVersion: 2,
        translation: RemoteTranslationConfig(provider: 'azure'),
        asr: RemoteAsrConfig(zhVcn: 'remote-vcn'),
        segmentation: SegmenterParams(silenceMs: 850),
        interpreter: RemoteInterpreterConfig(pretranslate: false),
        features: <String, bool>{'x': false},
        strings: <String, String>{'k': 'v'},
        systemPrompt: 'prompt',
        glossary: <String, String>{'g': 'h'},
        secrets: <String, String>{'translation.key': 'SECRET'},
      );

      final RemoteConfigApplyResult result = applyRemoteConfig(
        cfg,
        translation: t,
        speech: s,
        state: st,
      );

      // Tier A：写入 state。
      for (final String f in <String>[
        'segmentation',
        'interpreter',
        'features',
        'strings',
        'prompts.systemPrompt',
        'glossary',
      ]) {
        expect(result.hasApplied(f), isTrue, reason: '$f 应默认应用');
      }
      expect(st.configVersion, 2);
      expect(st.segmenter.silenceMs, 850);
      expect(st.pretranslate, isFalse);
      expect(st.text('k', 'fallback'), 'v');
      expect(st.isEnabled('x'), isFalse);
      expect(st.systemPrompt, 'prompt');
      expect(st.glossary['g'], 'h');

      // Tier B：默认全部跳过，两个配置单例保持原值。
      expect(result.hasSkipped('translation.provider'), isTrue);
      expect(result.hasSkipped('asr.zhVcn'), isTrue);
      expect(result.hasSkipped('secrets.translation.key'), isTrue);
      expect(t.provider, isNot(TranslationProvider.azure));
      expect(s.zhVcn, isNot('remote-vcn'));
      expect(t.key, isNot('SECRET'));
      // state 里根本不存在密钥。
      expect(st.current.secrets, isEmpty);
      expect(st.current.translation.isEmpty, isTrue);
      expect(st.current.asr.isEmpty, isTrue);
    });

    test('空配置不写空、不误报 applied', () {
      final RemoteConfigApplyResult result = applyRemoteConfig(
        RemoteConfig.empty,
        translation: TranslationConfig(),
        speech: SpeechConfig(),
        state: RemoteConfigState(),
      );
      expect(result.applied, isEmpty);
      expect(result.skipped, isEmpty);
    });
  });

  group('applyRemoteConfig 敏感项 opt-in', () {
    RemoteConfig sensitiveConfig() => const RemoteConfig(
          translation: RemoteTranslationConfig(
            provider: 'azure',
            region: 'eastasia',
            ugCode: 'ug',
            endpoint: 'https://nas.example.com/translate',
          ),
          asr: RemoteAsrConfig(
            ugVcn: 'ug-vcn',
            zhVcn: 'zh-vcn',
            endpoint: 'wss://nas.example.com/asr',
          ),
        );

    test('打开 trustSensitive 且 host 匹配时生效', () {
      final TranslationConfig t = TranslationConfig();
      final SpeechConfig s = SpeechConfig();
      final RemoteConfigApplyResult result = applyRemoteConfig(
        sensitiveConfig(),
        translation: t,
        speech: s,
        state: RemoteConfigState(),
        options: const RemoteConfigApplyOptions(
          trustSensitive: true,
          allowedHosts: <String>{'nas.example.com'},
        ),
      );
      expect(t.provider, TranslationProvider.azure);
      expect(t.region, 'eastasia');
      expect(t.ugCode, 'ug');
      expect(t.endpoint, 'https://nas.example.com/translate');
      expect(s.ugVcn, 'ug-vcn');
      expect(s.zhVcn, 'zh-vcn');
      expect(s.endpoint, 'wss://nas.example.com/asr');
      expect(result.hasApplied('translation.endpoint'), isTrue);
      expect(result.hasApplied('asr.endpoint'), isTrue);
      expect(result.hasApplied('translation.provider'), isTrue);
    });

    test('host 不在白名单时 endpoint 跳过，其余敏感项仍生效', () {
      final TranslationConfig t = TranslationConfig();
      final RemoteConfigApplyResult result = applyRemoteConfig(
        sensitiveConfig(),
        translation: t,
        speech: SpeechConfig(),
        state: RemoteConfigState(),
        options: const RemoteConfigApplyOptions(
          trustSensitive: true,
          allowedHosts: <String>{'other.example.com'},
        ),
      );
      expect(result.hasSkipped('translation.endpoint'), isTrue);
      expect(result.hasSkipped('asr.endpoint'), isTrue);
      expect(t.endpoint, isEmpty);
      expect(t.provider, TranslationProvider.azure);
    });

    test('http/ws 非安全协议：默认拒绝，局域网 + allowInsecureHttp 才放行', () {
      const RemoteConfig httpCfg = RemoteConfig(
        translation: RemoteTranslationConfig(
          endpoint: 'http://192.168.1.10/proxy',
        ),
      );
      final TranslationConfig t1 = TranslationConfig();
      final RemoteConfigApplyResult blocked = applyRemoteConfig(
        httpCfg,
        translation: t1,
        speech: SpeechConfig(),
        state: RemoteConfigState(),
        options: const RemoteConfigApplyOptions(
          trustSensitive: true,
          allowedHosts: <String>{'192.168.1.10'},
        ),
      );
      expect(blocked.hasSkipped('translation.endpoint'), isTrue);

      final TranslationConfig t2 = TranslationConfig();
      final RemoteConfigApplyResult allowed = applyRemoteConfig(
        httpCfg,
        translation: t2,
        speech: SpeechConfig(),
        state: RemoteConfigState(),
        options: const RemoteConfigApplyOptions(
          trustSensitive: true,
          allowInsecureHttp: true,
          allowedHosts: <String>{'192.168.1.10'},
        ),
      );
      expect(allowed.hasApplied('translation.endpoint'), isTrue);
      expect(t2.endpoint, 'http://192.168.1.10/proxy');
    });

    test('带 userinfo / 错 scheme 的 endpoint 一律拒绝', () {
      final TranslationConfig t = TranslationConfig();
      final SpeechConfig s = SpeechConfig();
      final RemoteConfigApplyResult result = applyRemoteConfig(
        const RemoteConfig(
          translation: RemoteTranslationConfig(
            endpoint: 'https://user:pw@nas.example.com/x',
          ),
          asr: RemoteAsrConfig(
            endpoint: 'https://nas.example.com/asr', // 应为 wss
          ),
        ),
        translation: t,
        speech: s,
        state: RemoteConfigState(),
        options: const RemoteConfigApplyOptions(trustSensitive: true),
      );
      expect(result.hasSkipped('translation.endpoint'), isTrue);
      expect(result.hasSkipped('asr.endpoint'), isTrue);
      expect(t.endpoint, isEmpty);
      expect(s.endpoint, isEmpty);
    });
  });

  group('密钥最严格', () {
    const RemoteConfig withSecret = RemoteConfig(
      secrets: <String, String>{'translation.key': 'SECRET'},
    );

    test('trustSecrets 未开则永不下发', () {
      final TranslationConfig t = TranslationConfig();
      final RemoteConfigApplyResult result = applyRemoteConfig(
        withSecret,
        translation: t,
        speech: SpeechConfig(),
        state: RemoteConfigState(),
        options: const RemoteConfigApplyOptions(trustSensitive: true),
      );
      expect(result.hasSkipped('secrets.translation.key'), isTrue);
      expect(t.key, isNot('SECRET'));
    });

    test('内置凭证包即便全开也永不被覆盖', () {
      final TranslationConfig t = TranslationConfig();
      final RemoteConfigApplyResult result = applyRemoteConfig(
        withSecret,
        translation: t,
        speech: SpeechConfig(),
        state: RemoteConfigState(),
        options: const RemoteConfigApplyOptions(
          trustSensitive: true,
          trustSecrets: true,
          bundledCredentials: true,
        ),
      );
      expect(result.skipped['secrets.translation.key'],
          contains('内置凭证包'));
      expect(t.key, isNot('SECRET'));
    });

    test('非内置 + 双重 opt-in 才写入内存（不落盘）', () {
      final TranslationConfig t = TranslationConfig();
      final SpeechConfig s = SpeechConfig();
      const RemoteConfig multi = RemoteConfig(
        secrets: <String, String>{
          'translation.appId': 'A',
          'translation.key': 'B',
          'speech.appId': 'C',
          'speech.apiKey': 'D',
          'speech.apiSecret': 'E',
        },
      );
      final RemoteConfigApplyResult result = applyRemoteConfig(
        multi,
        translation: t,
        speech: s,
        state: RemoteConfigState(),
        options: const RemoteConfigApplyOptions(
          trustSensitive: true,
          trustSecrets: true,
          bundledCredentials: false,
        ),
      );
      expect(t.appId, 'A');
      expect(t.key, 'B');
      expect(s.appId, 'C');
      expect(s.apiKey, 'D');
      expect(s.apiSecret, 'E');
      expect(result.applied.where((String f) => f.startsWith('secrets.')).length,
          5);
    });
  });

  group('RemoteConfigState', () {
    test('预译默认 true，手动覆盖后可被新配置清空', () {
      final RemoteConfigState st = RemoteConfigState();
      expect(st.pretranslate, isTrue);
      st.setPretranslate(false);
      expect(st.pretranslate, isFalse);

      st.applyFrom(const RemoteConfig(
        interpreter: RemoteInterpreterConfig(pretranslate: true),
      ));
      expect(st.pretranslate, isTrue, reason: '新配置到达，远程值重新优先');

      st.setPretranslate(false);
      expect(st.pretranslate, isFalse);
      st.applyFrom(RemoteConfig.empty);
      expect(st.pretranslate, isTrue, reason: '清空 override 后回到编译期默认');
    });

    test('text / isEnabled 缺失时沿用 fallback；rotate 默认对齐编排器', () {
      final RemoteConfigState st = RemoteConfigState();
      expect(st.text('missing', 'fallback'), 'fallback');
      expect(st.isEnabled('missing'), isTrue);
      expect(st.isEnabled('missing', fallback: false), isFalse);
      expect(st.rotateAfterMs, 45000);
      expect(st.forceRotateAfterMs, 54000);
      expect(st.maxSessionFailures, 2);
    });

    test('reset 回到全沿用', () {
      final RemoteConfigState st = RemoteConfigState();
      st.applyFrom(const RemoteConfig(
        configVersion: 9,
        strings: <String, String>{'k': 'v'},
      ));
      expect(st.configVersion, 9);
      st.reset();
      expect(st.configVersion, 0);
      expect(st.text('k', 'fallback'), 'fallback');
    });
  });

  group('SegmenterParams.build', () {
    test('远程值覆盖默认，空值沿用编译期默认', () {
      final SpeechSegmenter seg = const SegmenterParams(
        silenceMs: 850,
        maxDraftsPerSentence: 2,
        speechThreshold: 0.3,
      ).build(TranslationDirection.zhToUg);
      expect(seg.silenceMs, 850);
      expect(seg.maxDraftsPerSentence, 2);
      expect(seg.speechThreshold, 0.3);
      // 未指定的字段沿用默认。
      expect(seg.maxZhChars, kDefaultMaxZhChars);
      expect(seg.maxSentenceMs, kDefaultMaxSentenceMs);
      expect(seg.minDraftUgChars, kDefaultMinDraftUgChars);
    });

    test('全空参数构造出与编译期默认一致的断句器', () {
      final SpeechSegmenter seg =
          const SegmenterParams().build(TranslationDirection.ugToZh);
      expect(seg.silenceMs, kDefaultSilenceMs);
      expect(seg.maxDraftsPerSentence, kDefaultMaxDraftsPerSentence);
    });
  });
}
