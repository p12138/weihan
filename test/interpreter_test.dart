import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/interpreter.dart';
import 'package:uyghur_interpreter/live_asr.dart';

class _FakeSession implements LiveAsrSession, PartialAsrSession {
  final List<Uint8List> added = <Uint8List>[];
  int finishes = 0;
  int cancels = 0;
  String finalText = '';

  void Function(String)? _partial;
  void Function()? _done;
  void Function(Object)? _failure;

  @override
  void add(Uint8List pcm) => added.add(pcm);

  @override
  Future<String> finish() async {
    finishes += 1;
    return finalText;
  }

  @override
  Future<void> cancel() async {
    cancels += 1;
  }

  @override
  void setPartialListener(void Function(String accumulated)? listener) {
    _partial = listener;
  }

  @override
  void setDoneListener(void Function()? listener) {
    _done = listener;
  }

  @override
  void setFailureListener(void Function(Object error)? listener) {
    _failure = listener;
  }

  void emit(String text) => _partial?.call(text);

  void endFromServer() => _done?.call();

  void fail(Object error) => _failure?.call(error);
}

class _PlainSession implements LiveAsrSession {
  @override
  void add(Uint8List pcm) {}

  @override
  Future<String> finish() async => '';

  @override
  Future<void> cancel() async {}
}

class _ScriptedTranslator extends Translator {
  final List<String> calls = <String>[];
  final List<Completer<Translation>> pending = <Completer<Translation>>[];

  @override
  Future<Translation> translate(String text, Language from, Language to) {
    calls.add(text);
    final Completer<Translation> completer = Completer<Translation>();
    pending.add(completer);
    return completer.future;
  }

  void succeed(int index, String text) {
    pending[index].complete(
      Translation(text: text, provider: 'fake', found: true, isDemo: false),
    );
  }

  void fail(int index) {
    pending[index].complete(
      const Translation(text: '', provider: 'fake', found: false),
    );
  }
}

class _ThrowingTranslator extends Translator {
  @override
  Future<Translation> translate(String text, Language from, Language to) =>
      Future<Translation>.error(StateError('mt down'));
}

Future<void> _settle() async {
  for (int i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('句末标点先出原文定稿，译文返回后用同一个 key 补齐', () async {
    final _FakeSession session = _FakeSession();
    final _ScriptedTranslator translator = _ScriptedTranslator();
    final List<InterpreterSentence> sentences = <InterpreterSentence>[];
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: translator,
      openSession: (Language language) => session,
      onSentence: sentences.add,
    );

    expect(interpreter.start(), isTrue);
    session.emit('你好。');
    await _settle();

    expect(sentences.length, 1);
    expect(sentences.single.key, 's0');
    expect(sentences.single.source, '你好。');
    expect(sentences.single.pending, isTrue);
    expect(translator.calls, <String>['你好。']);

    translator.succeed(0, 'سالام');
    await _settle();

    expect(sentences.length, 2);
    expect(sentences.last.key, 's0');
    expect(sentences.last.pending, isFalse);
    expect(sentences.last.translation.found, isTrue);
    expect(sentences.last.translation.text, 'سالام');
  });

  test('句子没结束也能出预译草稿，最终仍由整句覆盖', () async {
    final _FakeSession session = _FakeSession();
    final _ScriptedTranslator translator = _ScriptedTranslator();
    final List<InterpreterDraft> drafts = <InterpreterDraft>[];
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: translator,
      openSession: (Language language) => session,
      onDraft: drafts.add,
    );

    interpreter.start();
    session.emit('你好世界，我们');
    await _settle();
    expect(translator.calls, <String>['你好世界，我们']);

    translator.succeed(0, 'سالام دۇنيا');
    await _settle();
    final InterpreterDraft draft =
        drafts.lastWhere((InterpreterDraft item) => item.translation != null);
    expect(draft.key, 's0');
    expect(draft.translation!.found, isTrue);
  });

  test('两句定稿按顺序上屏，不会因为后一句先返回而乱序', () async {
    final _FakeSession session = _FakeSession();
    final _ScriptedTranslator translator = _ScriptedTranslator();
    final List<InterpreterSentence> sentences = <InterpreterSentence>[];
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: translator,
      openSession: (Language language) => session,
      onSentence: sentences.add,
    );

    interpreter.start();
    session.emit('第一句。');
    session.emit('第一句。第二句。');
    await _settle();
    expect(translator.calls.length, 1, reason: '同一时刻只允许一个翻译在飞');

    translator.succeed(0, 'بىرىنچى.');
    await _settle();
    expect(translator.calls.length, 2);

    translator.succeed(1, 'ئىككىنچى.');
    await _settle();

    final List<InterpreterSentence> finals = sentences
        .where((InterpreterSentence item) => !item.pending)
        .toList();
    expect(finals.map((InterpreterSentence item) => item.key), <String>['s0', 's1']);
    expect(finals.first.translation.text, 'بىرىنچى.');
    expect(finals.last.translation.text, 'ئىككىنچى.');
  });

  test('停止会等最后一句翻译落地，再回调 onClosed', () async {
    final _FakeSession session = _FakeSession();
    final _ScriptedTranslator translator = _ScriptedTranslator();
    final List<InterpreterSentence> sentences = <InterpreterSentence>[];
    String? closedReason;
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: translator,
      openSession: (Language language) => session,
      onSentence: sentences.add,
      onClosed: (String reason) => closedReason = reason,
    );

    interpreter.start();
    session.emit('最后一句。');
    await _settle();
    final Future<void> stopping = interpreter.stop();
    await _settle();

    expect(sentences.last.pending, isTrue);
    translator.succeed(0, 'ئاخىرقى جۈملە.');
    await stopping;

    expect(sentences.last.pending, isFalse);
    expect(closedReason, '');
  });

  test('取消后不再产出译文，也不抛未捕获异常', () async {
    final _FakeSession session = _FakeSession();
    final _ScriptedTranslator translator = _ScriptedTranslator();
    final List<InterpreterSentence> sentences = <InterpreterSentence>[];
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: translator,
      openSession: (Language language) => session,
      onSentence: sentences.add,
    );

    interpreter.start();
    session.emit('你好。');
    await _settle();
    await interpreter.cancel();
    translator.succeed(0, 'سالام');
    await _settle();

    expect(
      sentences.where((InterpreterSentence item) => !item.pending),
      isEmpty,
    );
    expect(session.cancels, 1);
  });

  test('服务端主动结束会话后自动开新连接，不断流', () async {
    final List<_FakeSession> sessions = <_FakeSession>[];
    final _ScriptedTranslator translator = _ScriptedTranslator();
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: translator,
      openSession: (Language language) {
        final _FakeSession session = _FakeSession();
        sessions.add(session);
        return session;
      },
    );

    interpreter.start();
    expect(sessions.length, 1);
    sessions.first.emit('你好。');
    sessions.first.endFromServer();
    await _settle();

    expect(sessions.length, 2, reason: 'eos 后要继续听');
    expect(sessions.first.finishes, 1, reason: '旧会话要收尾关闭');
  });

  test('本段音频到 45 秒且刚发生句边界时换连接', () async {
    final List<_FakeSession> sessions = <_FakeSession>[];
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: _ScriptedTranslator(),
      openSession: (Language language) {
        final _FakeSession session = _FakeSession();
        sessions.add(session);
        return session;
      },
      rotateAfterMs: 2000,
      forceRotateAfterMs: 5000,
    );

    interpreter.start();
    interpreter.addAudio(Uint8List(32000), 0.5); // 1 秒
    sessions.first.emit('你好。');
    interpreter.addAudio(Uint8List(32000), 0.5); // 2 秒，边界刚过 1 秒
    await _settle();

    expect(sessions.length, 2);
  });

  test('连接反复失败才停止，单次失败先换连接', () async {
    final List<_FakeSession> sessions = <_FakeSession>[];
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: _ScriptedTranslator(),
      openSession: (Language language) {
        final _FakeSession session = _FakeSession();
        sessions.add(session);
        return session;
      },
    );

    interpreter.start();
    sessions.first.fail(StateError('socket down'));
    await _settle();
    expect(sessions.length, 2, reason: '第一次失败先重连');

    sessions[1].fail(StateError('socket down'));
    await _settle();
    expect(interpreter.isRunning, isFalse);
  });

  test('翻译抛异常时保留原文并给出 found=false，不产生未捕获异常', () async {
    final _FakeSession session = _FakeSession();
    final List<InterpreterSentence> sentences = <InterpreterSentence>[];
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: _ThrowingTranslator(),
      openSession: (Language language) => session,
      onSentence: sentences.add,
    );

    interpreter.start();
    session.emit('你好。');
    await _settle();

    final InterpreterSentence finalSentence = sentences.last;
    expect(finalSentence.source, '你好。');
    expect(finalSentence.translation.found, isFalse);
    expect(finalSentence.pending, isFalse);
  });

  test('译文脚本不对时判为未返回，不把原文当译文', () async {
    final _FakeSession session = _FakeSession();
    final _ScriptedTranslator translator = _ScriptedTranslator();
    final List<InterpreterSentence> sentences = <InterpreterSentence>[];
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: translator,
      openSession: (Language language) => session,
      onSentence: sentences.add,
    );

    interpreter.start();
    session.emit('你好。');
    await _settle();
    translator.succeed(0, 'hello');
    await _settle();

    expect(sentences.last.translation.found, isFalse);
    expect(sentences.last.translation.text, isEmpty);
  });

  test('端口不支持中间结果时 start 返回 false 并关闭会话', () async {
    final _PlainSession session = _PlainSession();
    String? closedReason;
    final LiveInterpreter interpreter = LiveInterpreter(
      direction: TranslationDirection.zhToUg,
      translator: _ScriptedTranslator(),
      openSession: (Language language) => session,
      onClosed: (String reason) => closedReason = reason,
    );

    expect(interpreter.start(), isFalse);
    expect(closedReason, contains('不支持'));
  });

  test('looksLikeTarget 挡住目标语言脚本不对的译文', () {
    expect(looksLikeTarget('سالام', Language.uyghur), isTrue);
    expect(looksLikeTarget('你好', Language.uyghur), isFalse);
    expect(looksLikeTarget('你好', Language.chinese), isTrue);
    expect(looksLikeTarget('hello', Language.chinese), isFalse);
    expect(looksLikeTarget('123', Language.chinese), isTrue);
  });
}
