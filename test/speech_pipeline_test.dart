// 三环编排单测：录音 → 识别 → 翻译 → 合成，全部用假端口，不发网络。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/speech_pipeline.dart';
import 'package:uyghur_interpreter/xfyun_speech.dart' show SpeechException;

class _FakeSpeech extends SpeechPort {
  _FakeSpeech({this.heard = '你好'});

  String heard;
  final List<String> calls = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Future<String> listen(Uint8List audio, Language language) async {
    calls.add('listen:${language.code}:${audio.length}');
    return heard;
  }

  @override
  Future<Uint8List> speak(String text, Language language) async {
    calls.add('speak:$text:${language.code}');
    return Uint8List.fromList(<int>[1, 2, 3]);
  }
}

class _FakeTranslator extends Translator {
  _FakeTranslator({this.found = true});

  final bool found;
  final List<String> calls = <String>[];

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async {
    calls.add('$text:${from.code}->${to.code}');
    return found
        ? const Translation(
            text: 'ئەسسالامۇ ئەلەيكۇم',
            provider: '假服务',
            found: true,
            isDemo: false,
          )
        : const Translation(text: '', provider: '假服务', found: false);
  }
}

void main() {
  test('中译维：按识别 → 翻译 → 合成顺序执行', () async {
    final _FakeSpeech speech = _FakeSpeech();
    final _FakeTranslator translator = _FakeTranslator();
    final SpeechPipeline pipeline = SpeechPipeline(
      speech: speech,
      translator: translator,
    );
    final SpeechTurn turn = await pipeline.run(
      Uint8List.fromList(<int>[0, 1]),
      TranslationDirection.zhToUg,
    );

    expect(turn.heard, '你好');
    expect(turn.translation.text, 'ئەسسالامۇ ئەلەيكۇم');
    expect(turn.hasAudio, isTrue);
    expect(turn.audio.toList(), <int>[1, 2, 3]);
    expect(translator.calls, <String>['你好:zh->ug']);
    expect(speech.calls, <String>[
      'listen:zh:2',
      'speak:ئەسسالامۇ ئەلەيكۇم:ug',
    ]);
  });

  test('维译中：方向与语言参数同步翻转', () async {
    final _FakeSpeech speech = _FakeSpeech(heard: 'ياخشىمۇسىز');
    final _FakeTranslator translator = _FakeTranslator();
    final SpeechPipeline pipeline = SpeechPipeline(
      speech: speech,
      translator: translator,
    );
    await pipeline.run(
      Uint8List.fromList(<int>[0]),
      TranslationDirection.ugToZh,
    );
    expect(speech.calls.first, 'listen:ug:1');
    expect(translator.calls.single, 'ياخشىمۇسىز:ug->zh');
    expect(speech.calls.last, 'speak:ئەسسالامۇ ئەلەيكۇم:zh');
  });

  test('翻译未命中时不调用合成，音频为空', () async {
    final _FakeSpeech speech = _FakeSpeech();
    final SpeechPipeline pipeline = SpeechPipeline(
      speech: speech,
      translator: _FakeTranslator(found: false),
    );
    final SpeechTurn turn = await pipeline.run(
      Uint8List.fromList(<int>[0]),
      TranslationDirection.zhToUg,
    );
    expect(turn.translation.found, isFalse);
    expect(turn.hasAudio, isFalse);
    expect(speech.calls, <String>['listen:zh:1']);
  });

  test('未识别到文字时抛出可读异常', () async {
    final SpeechPipeline pipeline = SpeechPipeline(
      speech: _FakeSpeech(heard: '  '),
      translator: _FakeTranslator(),
    );
    await expectLater(
      pipeline.run(
        Uint8List.fromList(<int>[0]),
        TranslationDirection.zhToUg,
      ),
      throwsA(isA<SpeechException>()),
    );
  });

  // 「说中文没有声音」曾经会连识别结果和译文一起消失：合成异常往外抛，
  // 整轮被当成失败。现在朗读失败只降级成提示。
  test('合成失败时译文仍然保留，原因写进 speakError', () async {
    final _FailingSpeech speech = _FailingSpeech();
    final SpeechPipeline pipeline = SpeechPipeline(
      speech: speech,
      translator: _FakeTranslator(),
    );
    final SpeechTurn turn = await pipeline.run(
      Uint8List.fromList(<int>[0, 1]),
      TranslationDirection.zhToUg,
    );

    expect(turn.heard, '你好');
    expect(turn.translation.found, isTrue);
    expect(turn.translation.text, 'ئەسسالامۇ ئەلەيكۇم');
    expect(turn.hasAudio, isFalse);
    expect(turn.speakError, contains('维语发音人'));
  });

  test('合成返回空音频时也给出 speakError', () async {
    final SpeechPipeline pipeline = SpeechPipeline(
      speech: _EmptyAudioSpeech(),
      translator: _FakeTranslator(),
    );
    final SpeechTurn turn = await pipeline.run(
      Uint8List.fromList(<int>[0]),
      TranslationDirection.zhToUg,
    );
    expect(turn.translation.found, isTrue);
    expect(turn.hasAudio, isFalse);
    expect(turn.speakError, isNotNull);
  });
}

/// 合成必败的端口，模拟「维语发音人没开通」。
class _FailingSpeech extends _FakeSpeech {
  @override
  Future<Uint8List> speak(String text, Language language) async {
    throw const SpeechException(
      '维语发音人 vcn 未配置 · 到设置页填讯飞「发音人管理」里的维吾尔语发音人',
    );
  }
}

/// 合成「成功」但一个字节都没有，模拟控制台没开通却返回 200 的情况。
class _EmptyAudioSpeech extends _FakeSpeech {
  @override
  Future<Uint8List> speak(String text, Language language) async =>
      Uint8List(0);
}
