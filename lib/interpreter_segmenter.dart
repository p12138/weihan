// 同声传译的断句器：纯 Dart、无 I/O、无 Timer。
//
// 输入是「本会话累计识别文本」和「音频时钟 + 音量」，输出是四类事件：
//   - sourceDraft：当前未提交句子的原文，界面用来持续更新草稿气泡；
//   - sentence：一句已经结束、可以定稿翻译的完整原文；
//   - draftRequest：句子还没结束时，先翻一个稳定前缀做预译；
//   - （会话轮换由上层按 audioMs 与句边界决定，这里不掺和网络生命周期）
//
// 为什么用音频时钟而不是 Timer：每块 PCM 16k/16bit/单声道 = 32000 字节/秒，
// `ms = bytes ~/ 32` 完全确定；Timer 会让 widget 测试的 pumpAndSettle 不收敛。
//
// 断句的主信号是**静音**，标点只是加速器：维语 ASR 很少带句末标点，若只认
// 标点，维语方向会一直不提交；反过来，partial 可能停在半个维语单词上，
// 所以维语的稳定前缀必须切在最后一个空格。

import 'conversation.dart';

/// 断句器默认参数。抽成常量，让 [SpeechSegmenter] 与 [SegmenterParams]
/// （远程配置）共用同一份默认值，避免两处漂移。
const double kDefaultSpeechThreshold = 0.12;
const int kDefaultSilenceMs = 700;
const int kDefaultMaxSentenceMs = 10000;
const int kDefaultMaxZhChars = 60;
const int kDefaultMaxUgChars = 200;
const int kDefaultMinDraftZhChars = 6;
const int kDefaultMinDraftUgChars = 10;
const int kDefaultDraftGapMs = 1200;
const int kDefaultMaxDraftsPerSentence = 1;

/// 断句器事件类型。
enum SegmentEventKind {
  /// 当前未提交句子的原文（可能为空）。
  sourceDraft,

  /// 一句话结束，可以整句翻译并定稿。
  sentence,

  /// 句子还没结束，先翻这个稳定前缀做预译。
  draftRequest,
}

/// 断句器事件。用单一类型 + kind，避免上层写一堆子类判断。
class SegmentEvent {
  const SegmentEvent(this.kind, [this.text = '']);

  final SegmentEventKind kind;
  final String text;

  @override
  String toString() => 'SegmentEvent($kind, $text)';
}

/// 一句未结束的话能先翻多长：中文按字符，维语切到最后一个空格。
class SpeechSegmenter {
  SpeechSegmenter({
    required this.direction,
    this.speechThreshold = kDefaultSpeechThreshold,
    this.silenceMs = kDefaultSilenceMs,
    this.maxSentenceMs = kDefaultMaxSentenceMs,
    this.maxZhChars = kDefaultMaxZhChars,
    this.maxUgChars = kDefaultMaxUgChars,
    this.minDraftZhChars = kDefaultMinDraftZhChars,
    this.minDraftUgChars = kDefaultMinDraftUgChars,
    this.draftGapMs = kDefaultDraftGapMs,
    this.maxDraftsPerSentence = kDefaultMaxDraftsPerSentence,
  });

  final TranslationDirection direction;

  /// `levelFromPcm` 的 0..1 音量，超过它算在说话。
  final double speechThreshold;

  /// 连续低电平多久算一句结束。0.7 秒是「同传」和「别老切碎」的折中。
  final int silenceMs;

  /// 单句最长音频；长独白不停顿也要强制切，否则一直等不到译文。
  final int maxSentenceMs;

  final int maxZhChars;
  final int maxUgChars;
  final int minDraftZhChars;
  final int minDraftUgChars;

  /// 两次预译之间至少隔这么久，控制 API 消耗。
  final int draftGapMs;

  /// 每句最多预译几次；默认 1，最终仍会被整句译文覆盖。
  final int maxDraftsPerSentence;

  String _text = '';
  int _committed = 0;
  int _audioMs = 0;
  int _quietMs = 0;
  int _sentenceMs = 0;
  bool _heardSpeech = false;

  int _draftsThisSentence = 0;
  int _lastDraftAtMs = -1 << 30;
  String? _lastDraftSrc;

  /// 本会话累计文本（最近一次 [onText] 的内容）。
  String get text => _text;

  /// 已提交（已定稿）的字符数。
  int get committed => _committed;

  /// 当前未提交的原文。
  String get pending =>
      _committed >= _text.length ? '' : _text.substring(_committed);

  /// 当前会话累计音频时长。
  int get audioMs => _audioMs;

  /// 服务端返回新的累计文本。
  ///
  /// 文本只允许变长：讯飞未开动态修正时是追加语义，上层拼接也保证单调。
  /// 万一收到更短的（网关回退/会话重启），保留已有最长前缀，不让已经上屏的
  /// 内容突然消失。
  List<SegmentEvent> onText(String accumulated) {
    if (accumulated.length < _text.length) {
      return const <SegmentEvent>[];
    }
    _text = accumulated;
    final List<SegmentEvent> events = <SegmentEvent>[];
    _commitByPunctuation(events);
    events.add(SegmentEvent(SegmentEventKind.sourceDraft, pending));
    _maybeDraft(events);
    return events;
  }

  /// 收到一块音频。只推进时钟与静音判定，不碰 PCM 内容。
  List<SegmentEvent> onAudio({required int audioMs, required double level}) {
    if (audioMs <= 0) {
      return const <SegmentEvent>[];
    }
    _audioMs += audioMs;
    _sentenceMs += audioMs;
    if (level >= speechThreshold) {
      _quietMs = 0;
      _heardSpeech = true;
    } else {
      _quietMs += audioMs;
    }

    final List<SegmentEvent> events = <SegmentEvent>[];
    if (_heardSpeech && _quietMs >= silenceMs) {
      _commitAll(events);
    } else if (pending.length >= _maxChars) {
      _commitSoft(events, _maxChars);
    }
    if (_sentenceMs >= maxSentenceMs && pending.trim().isNotEmpty) {
      _commitSoft(events, pending.length);
    }
    if (events.isNotEmpty) {
      events.add(SegmentEvent(SegmentEventKind.sourceDraft, pending));
    }
    return events;
  }

  /// 会话结束 / 用户点停止：把剩余未提交文本提交掉。
  List<SegmentEvent> finishSentence() {
    final List<SegmentEvent> events = <SegmentEvent>[];
    _commitAll(events);
    if (events.isNotEmpty) {
      events.add(SegmentEvent(SegmentEventKind.sourceDraft, pending));
    }
    return events;
  }

  /// 新的连续同传会话：清空全部状态。
  void reset() {
    _text = '';
    _committed = 0;
    _audioMs = 0;
    _quietMs = 0;
    _sentenceMs = 0;
    _heardSpeech = false;
    _draftsThisSentence = 0;
    _lastDraftAtMs = -1 << 30;
    _lastDraftSrc = null;
  }

  int get _maxChars =>
      direction.source == Language.uyghur ? maxUgChars : maxZhChars;

  int get _minDraftChars =>
      direction.source == Language.uyghur ? minDraftUgChars : minDraftZhChars;

  static final RegExp _terminalPunct = RegExp(r'[。！？!?…；;؟۔]');
  static final RegExp _clausePunct = RegExp(r'[，、,;；،]');

  /// 标点加速：把已出现句末标点的部分一次性提交（可能一次提交多句）。
  void _commitByPunctuation(List<SegmentEvent> events) {
    while (true) {
      final Match? match = _terminalPunct.firstMatch(pending);
      if (match == null) {
        return;
      }
      final int end = _committed + match.end;
      if (!_commitTo(end, events)) {
        return;
      }
    }
  }

  /// 静音 / 结束时提交全部剩余文本。
  void _commitAll(List<SegmentEvent> events) {
    final String trimPending = pending;
    if (trimPending.trim().isEmpty) {
      _quietMs = 0;
      return;
    }
    _commitTo(_text.length, events);
    _quietMs = 0;
  }

  /// 超长强制切：优先切在最近的小句标点，其次空格，最后硬切。
  void _commitSoft(List<SegmentEvent> events, int limit) {
    final String segment = pending;
    if (segment.trim().isEmpty) {
      return;
    }
    final int capped = limit.clamp(1, segment.length).toInt();
    int cut = capped;
    for (int i = capped - 1; i >= 0; i--) {
      if (_clausePunct.hasMatch(segment[i])) {
        cut = i + 1;
        break;
      }
    }
    if (cut == capped) {
      final int space = segment.lastIndexOf(' ', capped - 1);
      if (space > 0) {
        cut = space + 1;
      }
    }
    _commitTo(_committed + cut, events);
  }

  /// 提交到 [end]（绝对字符下标）。空文本返回 false。
  bool _commitTo(int end, List<SegmentEvent> events) {
    if (end <= _committed || end > _text.length) {
      return false;
    }
    final String sentence = _text.substring(_committed, end).trim();
    _committed = end;
    _draftsThisSentence = 0;
    _lastDraftSrc = null;
    _sentenceMs = 0;
    _quietMs = 0;
    if (sentence.isNotEmpty) {
      events.add(SegmentEvent(SegmentEventKind.sentence, sentence));
    }
    return true;
  }

  /// 预译：只翻稳定前缀，每句最多 [maxDraftsPerSentence] 次。
  void _maybeDraft(List<SegmentEvent> events) {
    if (_draftsThisSentence >= maxDraftsPerSentence) {
      return;
    }
    if (_audioMs - _lastDraftAtMs < draftGapMs) {
      return;
    }
    final String segment = pending;
    if (segment.trim().isEmpty) {
      return;
    }
    // 没有小句标点又不够长时不预译，避免把「今天」这种碎片送出去。
    final bool hasClause = _clausePunct.hasMatch(segment);
    if (!hasClause && segment.length < _minDraftChars * 2) {
      return;
    }
    final String stable = _stablePrefix(segment);
    final String clean = stable.trim();
    if (clean.length < _minDraftChars || clean == _lastDraftSrc) {
      return;
    }
    _lastDraftSrc = clean;
    _lastDraftAtMs = _audioMs;
    _draftsThisSentence += 1;
    events.add(SegmentEvent(SegmentEventKind.draftRequest, clean));
  }

  /// 中文可以直接翻到当前末尾；维语必须切在最后一个空格，不能翻半个词。
  String _stablePrefix(String segment) {
    if (direction.source == Language.uyghur) {
      final int space = segment.lastIndexOf(' ');
      if (space <= 0) {
        return '';
      }
      return segment.substring(0, space);
    }
    return segment;
  }
}

/// 断句参数快照：远程配置里的 9 个可空字段，`null` = 沿用编译期默认。
///
/// 放在本文件而非另起一份，是为了让 [build] 的默认值直接取上面那组常量，
/// 与 [SpeechSegmenter] 同源，不会出现「配置默认 6、代码默认 7」的漂移。
/// 数值在 `RemoteConfig.parse` 里已按边界钳制，这里只做 `??` 兜底。
class SegmenterParams {
  const SegmenterParams({
    this.speechThreshold,
    this.silenceMs,
    this.maxSentenceMs,
    this.maxZhChars,
    this.maxUgChars,
    this.minDraftZhChars,
    this.minDraftUgChars,
    this.draftGapMs,
    this.maxDraftsPerSentence,
  });

  final double? speechThreshold;
  final int? silenceMs;
  final int? maxSentenceMs;
  final int? maxZhChars;
  final int? maxUgChars;
  final int? minDraftZhChars;
  final int? minDraftUgChars;
  final int? draftGapMs;
  final int? maxDraftsPerSentence;

  /// 用「远程值 ?? 编译期默认」构造一个真正的断句器。
  SpeechSegmenter build(TranslationDirection direction) => SpeechSegmenter(
        direction: direction,
        speechThreshold: speechThreshold ?? kDefaultSpeechThreshold,
        silenceMs: silenceMs ?? kDefaultSilenceMs,
        maxSentenceMs: maxSentenceMs ?? kDefaultMaxSentenceMs,
        maxZhChars: maxZhChars ?? kDefaultMaxZhChars,
        maxUgChars: maxUgChars ?? kDefaultMaxUgChars,
        minDraftZhChars: minDraftZhChars ?? kDefaultMinDraftZhChars,
        minDraftUgChars: minDraftUgChars ?? kDefaultMinDraftUgChars,
        draftGapMs: draftGapMs ?? kDefaultDraftGapMs,
        maxDraftsPerSentence:
            maxDraftsPerSentence ?? kDefaultMaxDraftsPerSentence,
      );

  /// 缓存用：只序列化非 null 字段，null 不写（下次读回仍是「沿用」）。
  Map<String, Object?> toJson() => <String, Object?>{
        if (speechThreshold != null) 'speechThreshold': speechThreshold,
        if (silenceMs != null) 'silenceMs': silenceMs,
        if (maxSentenceMs != null) 'maxSentenceMs': maxSentenceMs,
        if (maxZhChars != null) 'maxZhChars': maxZhChars,
        if (maxUgChars != null) 'maxUgChars': maxUgChars,
        if (minDraftZhChars != null) 'minDraftZhChars': minDraftZhChars,
        if (minDraftUgChars != null) 'minDraftUgChars': minDraftUgChars,
        if (draftGapMs != null) 'draftGapMs': draftGapMs,
        if (maxDraftsPerSentence != null)
          'maxDraftsPerSentence': maxDraftsPerSentence,
      };
}
