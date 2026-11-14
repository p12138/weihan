import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/conversation_page.dart';
import 'package:uyghur_interpreter/device_audio.dart';
import 'package:uyghur_interpreter/live_asr.dart';

class _ChunkAudioFake extends AudioPort implements ChunkedAudioPort {
  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast(sync: true);
  int starts = 0;
  int stops = 0;

  @override
  Stream<Uint8List> get pcmChunks => _chunks.stream;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> startRecord() async {
    starts += 1;
  }

  @override
  Future<Uint8List> stopRecord() async {
    stops += 1;
    return Uint8List(0);
  }

  @override
  Future<void> play(Uint8List audio) async {}

  @override
  void dispose() {
    if (!_chunks.isClosed) {
      _chunks.close();
    }
  }
}

class _PartialSession implements LiveAsrSession, PartialAsrSession {
  final List<Uint8List> added = <Uint8List>[];
  int finishes = 0;
  int cancels = 0;

  void Function(String)? _partial;

  @override
  void add(Uint8List pcm) => added.add(pcm);

  @override
  Future<String> finish() async {
    finishes += 1;
    return '';
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
  void setDoneListener(void Function()? listener) {}

  @override
  void setFailureListener(void Function(Object error)? listener) {}

  void emit(String text) => _partial?.call(text);
}

class _LiveSpeechFake extends SpeechPort implements LiveSpeechPort {
  _LiveSpeechFake(this.session);

  final _PartialSession session;

  @override
  bool get isAvailable => true;

  @override
  LiveAsrSession openLiveAsr(Language language) => session;

  @override
  Future<Uint8List> speak(String text, Language language) async =>
      Uint8List(0);
}

class _ImmediateTranslator extends Translator {
  int calls = 0;

  @override
  Future<Translation> translate(String text, Language from, Language to) async {
    calls += 1;
    return Translation(
      text: to == Language.uyghur ? 'سالام' : '你好',
      provider: 'fake',
      found: true,
      isDemo: false,
    );
  }
}

void main() {
  testWidgets('连续同传：草稿原位变大，定稿后覆盖且不新增气泡', (WidgetTester tester) async {
    final _ChunkAudioFake audio = _ChunkAudioFake();
    final _PartialSession session = _PartialSession();
    final _LiveSpeechFake speech = _LiveSpeechFake(session);
    final _ImmediateTranslator translator = _ImmediateTranslator();

    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          translator: translator,
          speech: speech,
          audio: audio,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('连续同传'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('voice-button')));
    await tester.pumpAndSettle();
    expect(audio.starts, 1);

    session.emit('你好');
    await tester.pump();
    await tester.pump();
    expect(find.text('你好'), findsOneWidget, reason: '边说边出原文草稿');

    session.emit('你好世界。');
    await tester.pump();
    await tester.pump();
    expect(find.text('你好世界。'), findsOneWidget);
    expect(find.text('你好'), findsNothing, reason: '草稿被原位替换，不是追加');
    expect(find.text('سالام'), findsOneWidget);
    expect(find.byType(MessageBubble), findsNWidgets(2),
        reason: '一句原文 + 一句译文，不能出现两份草稿');

    await tester.tap(find.byKey(const ValueKey<String>('voice-button')));
    await tester.pumpAndSettle();
    expect(audio.stops, 1);
    expect(session.finishes, 1);
    expect(find.byType(MessageBubble), findsNWidgets(2));
  });

  testWidgets('连续同传不可用时给出明确提示，不假装能用', (WidgetTester tester) async {
    final _ChunkAudioFake audio = _ChunkAudioFake();
    // 普通 SpeechPort 没有边录边传能力，也没有中间结果。
    final _PlainSpeech speech = _PlainSpeech();

    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          translator: _ImmediateTranslator(),
          speech: speech,
          audio: audio,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('连续同传'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('voice-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('不支持连续同传'), findsOneWidget);
    expect(audio.starts, 0);
  });
}

class _PlainSpeech extends SpeechPort {
  @override
  bool get isAvailable => true;
}
