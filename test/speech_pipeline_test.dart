// 三环编排单测：录音 → 识别 → 翻译 → 合成，全部用假端口，不发网络。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/live_asr.dart';
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

  // 「译文先上屏」用纯 Dart 顺序单测钉住：不依赖 widget 测试的 fake async，
  // 也不需要挂一个永不完成的 Completer 去卡住合成。
  test('低延迟回调：译文在合成发起之前就交给页面', () async {
    final List<String> events = <String>[];
    final _OrderSpeech speech = _OrderSpeech(events);
    final SpeechPipeline pipeline = SpeechPipeline(
      speech: speech,
      translator: _OrderTranslator(events),
    );
    final SpeechTurn turn = await pipeline.run(
      Uint8List.fromList(<int>[0, 1]),
      TranslationDirection.zhToUg,
      session: _OrderSession(events, '你好'),
      onHeard: (String heard) => events.add('heard:$heard'),
      onText: (String heard, Translation translation) =>
          events.add('text:${translation.text}'),
    );

    expect(events, <String>[
      'finish',
      'heard:你好',
      'translate',
      'text:ئەسسالامۇ ئەلەيكۇم',
      'speak',
    ], reason: '页面在 onText 就上屏，合成与朗读发生在它之后');
    expect(speech.listens, 0, reason: '边录边传成功时不整段重传');
    expect(turn.hasAudio, isTrue);
  });

  test('会话空识别时自动整段重传，仍按同一顺序回调', () async {
    final List<String> events = <String>[];
    final _OrderSpeech speech = _OrderSpeech(events);
    final SpeechPipeline pipeline = SpeechPipeline(
      speech: speech,
      translator: _OrderTranslator(events),
    );
    await pipeline.run(
      Uint8List.fromList(<int>[0]),
      TranslationDirection.zhToUg,
      session: _OrderSession(events, ''),
      onHeard: (String heard) => events.add('heard:$heard'),
    );

    expect(speech.listens, 1);
    expect(events.first, 'finish');
    expect(events, contains('listen'));
    expect(events, contains('heard:老路识别'));
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

/// 按调用顺序记事件的会话。
class _OrderSession implements LiveAsrSession {
  _OrderSession(this.events, this.result);

  final List<String> events;
  final String result;

  @override
  void add(Uint8List pcm) {
    events.add('add');
  }

  @override
  Future<String> finish() async {
    events.add('finish');
    return result;
  }

  @override
  Future<void> cancel() async {
    events.add('cancel');
  }
}

class _OrderSpeech extends SpeechPort {
  _OrderSpeech(this.events);

  final List<String> events;
  int listens = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<String> listen(Uint8List audio, Language language) async {
    listens += 1;
    events.add('listen');
    return '老路识别';
  }

  @override
  Future<Uint8List> speak(String text, Language language) async {
    events.add('speak');
    return Uint8List.fromList(<int>[1, 2, 3]);
  }
}

class _OrderTranslator extends Translator {
  _OrderTranslator(this.events);

  final List<String> events;

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async {
    events.add('translate');
    return const Translation(
      text: 'ئەسسالامۇ ئەلەيكۇم',
      provider: '顺序测试',
      found: true,
      isDemo: false,
    );
  }
}
