import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';
import 'package:uyghur_interpreter/interpreter_segmenter.dart';

List<String> _of(List<SegmentEvent> events, SegmentEventKind kind) =>
    <String>[
      for (final SegmentEvent event in events)
        if (event.kind == kind) event.text,
    ];

void main() {
  test('句末标点立即提交，剩余文本变成新的草稿', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.zhToUg);
    final List<SegmentEvent> events = segmenter.onText('你好。世界');

    expect(_of(events, SegmentEventKind.sentence), <String>['你好。']);
    expect(_of(events, SegmentEventKind.sourceDraft), <String>['世界']);
    expect(segmenter.pending, '世界');
    expect(segmenter.committed, 3);
  });

  test('静音 700ms 才提交，不说 0.7 秒就切碎', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.zhToUg);
    segmenter.onText('今天天气很好');

    expect(
      _of(segmenter.onAudio(audioMs: 320, level: 0.5),
          SegmentEventKind.sentence),
      isEmpty,
    );
    expect(
      _of(segmenter.onAudio(audioMs: 320, level: 0.02),
          SegmentEventKind.sentence),
      isEmpty,
      reason: '才安静 320ms，不能提交',
    );
    expect(
      _of(segmenter.onAudio(audioMs: 320, level: 0.02),
          SegmentEventKind.sentence),
      isEmpty,
      reason: '640ms 仍不到阈值',
    );
    expect(
      _of(segmenter.onAudio(audioMs: 320, level: 0.02),
          SegmentEventKind.sentence),
      <String>['今天天气很好'],
      reason: '960ms 静音应该定稿',
    );
  });

  test('预译每句最多一次，且只翻小句边界前的稳定前缀', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.zhToUg);
    final List<SegmentEvent> first = segmenter.onText('你好世界，我们');
    expect(
      _of(first, SegmentEventKind.draftRequest),
      <String>['你好世界，我们'],
    );

    final List<SegmentEvent> second = segmenter.onText('你好世界，我们走吧');
    expect(
      _of(second, SegmentEventKind.draftRequest),
      isEmpty,
      reason: '同一句最多预译一次，最终由整句译文覆盖',
    );
  });

  test('没有小句标点又不够长时不预译，避免翻译碎片', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.zhToUg);
    final List<SegmentEvent> events = segmenter.onText('今天');
    expect(_of(events, SegmentEventKind.draftRequest), isEmpty);
  });

  test('维语预译切在最后一个空格，不翻半个单词', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.ugToZh);
    // 维语没有小句标点时，文本要够长（minDraftUgChars * 2）才允许预译；
    // 末尾故意停在半个词 كۆ 上，验证稳定前缀把它切掉。
    final List<SegmentEvent> events =
        segmenter.onText('ياخشىمۇسىز دوستلار كۆ');
    expect(
      _of(events, SegmentEventKind.draftRequest),
      <String>['ياخشىمۇسىز دوستلار'],
    );
  });

  test('维语还没有空格时绝不预译', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.ugToZh);
    final List<SegmentEvent> events = segmenter.onText('ياخشىمۇسى');
    expect(_of(events, SegmentEventKind.draftRequest), isEmpty);
  });

  test('超长无标点文本按上限强制切，不会一直等不到译文', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.zhToUg);
    final String longText = List<String>.filled(70, '好').join();
    segmenter.onText(longText);
    final List<SegmentEvent> events =
        segmenter.onAudio(audioMs: 5000, level: 0.5);

    final List<String> sentences =
        _of(events, SegmentEventKind.sentence);
    expect(sentences.length, 1);
    expect(sentences.first.length, 60);
    expect(segmenter.pending.length, 10);
  });

  test('会话结束提交剩余文本', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.zhToUg);
    segmenter.onText('最后一句没有标点');
    final List<SegmentEvent> events = segmenter.finishSentence();
    expect(
      _of(events, SegmentEventKind.sentence),
      <String>['最后一句没有标点'],
    );
    expect(segmenter.pending, isEmpty);
  });

  test('收到更短的累计文本时保留已有内容，不回退', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.zhToUg);
    segmenter.onText('你好世界');
    final List<SegmentEvent> events = segmenter.onText('你好');
    expect(events, isEmpty);
    expect(segmenter.text, '你好世界');
  });

  test('reset 清空时钟与文本，下一轮从零开始', () {
    final SpeechSegmenter segmenter =
        SpeechSegmenter(direction: TranslationDirection.zhToUg);
    segmenter.onText('第一轮。');
    segmenter.onAudio(audioMs: 800, level: 0.5);
    segmenter.reset();

    expect(segmenter.text, isEmpty);
    expect(segmenter.audioMs, 0);
    expect(segmenter.committed, 0);
  });
}
