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
}
