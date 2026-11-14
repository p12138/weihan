// 连续同传的编排器：把「持续录音 → 断句 → 翻译 → 定稿」串起来。
//
// 只依赖端口（ASR 会话工厂 + Translator + 断句器），不碰 Flutter、不碰平台
// 插件、不持有 AudioPort，因此可以在纯 Dart 单测里用假会话驱动。
//
// 三条硬规则：
//   1. 定稿翻译 FIFO 且绝不丢；草稿只是 latest-wins，可随时丢弃。
//   2. 同一时刻只有一条 ASR 会话；服务端结束（eos）或本段音频到 45/54 秒时
//      换新连接，换连接发生在句边界，不让一句话被劈成两段。
//   3. 取消后不再产生任何回调，也不再发起新的翻译。

import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'conversation.dart';
import 'interpreter_segmenter.dart';
import 'live_asr.dart';

/// 同传草稿：原文持续变长，译文可能还没有（null）或只是预译。
class InterpreterDraft {
  const InterpreterDraft({
    required this.key,
    required this.source,
    this.translation,
  });

  /// 一句话的稳定标识；定稿时沿用同一个 key，页面据此原位替换。
  final String key;
  final String source;
  final Translation? translation;
}

/// 一句话定稿。[pending] 为 true 表示原文已定、译文还在路上。
class InterpreterSentence {
  const InterpreterSentence({
    required this.key,
    required this.source,
    required this.translation,
    this.pending = false,
  });

  final String key;
  final String source;
  final Translation translation;
  final bool pending;
}

/// 译文目标语言脚本检查：目标维语却一个阿拉伯字母都没有、或目标中文却
/// 一个汉字都没有，多半是原文回显 / 乱码。宁可显示「未返回译文」，也不
/// 把错的东西当译文给用户看。
bool looksLikeTarget(String text, Language target) {
  final String clean = text.trim();
  if (clean.isEmpty) {
    return false;
  }
  final bool hasLetters =
      RegExp(r'[A-Za-z\u0600-\u06FF\u4e00-\u9fff]').hasMatch(clean);
  if (!hasLetters) {
    return true; // 纯数字 / 标点，不判错
  }
  if (target == Language.uyghur) {
    return RegExp(r'[\u0600-\u06FF]').hasMatch(clean);
  }
  return RegExp(r'[\u4e00-\u9fff]').hasMatch(clean);
}

class LiveInterpreter {
  LiveInterpreter({
    required this.direction,
    required this.translator,
    required this.openSession,
    this.onDraft,
    this.onSentence,
    this.onStatus,
    this.onClosed,
    this.rotateAfterMs = 45000,
    this.forceRotateAfterMs = 54000,
    this.maxSessionFailures = 2,
    this.pretranslate = true,
  }) : _segmenter = SpeechSegmenter(direction: direction);

  final TranslationDirection direction;
  final Translator translator;

  /// 同步返回一条新的 ASR 会话；建连在会话内部异步进行。
  final LiveAsrSession Function(Language language) openSession;

  final void Function(InterpreterDraft draft)? onDraft;
  final void Function(InterpreterSentence sentence)? onSentence;
  final void Function(String status)? onStatus;

  /// 结束回调：正常停止时 reason 为空；异常停止时是给用户看的原因。
  final void Function(String reason)? onClosed;

  /// 本段音频达到 45 秒且在句边界时换连接。
  final int rotateAfterMs;

  /// 本段音频到 54 秒强制换连接（服务端会话上限 60 秒）。
  final int forceRotateAfterMs;

  final int maxSessionFailures;

  /// 句子没结束时是否先翻一次稳定前缀（每句最多一次，多一次 API 消耗）。
  final bool pretranslate;

  final SpeechSegmenter _segmenter;
  final List<_AsrSegment> _segments = <_AsrSegment>[];

  LiveAsrSession? _session;
  _AsrSegment? _current;
  int _nextSegment = 0;
  int _segmentAudioMs = 0;
  int _failures = 0;
  bool _rotating = false;
  bool _started = false;
  bool _stopping = false;
  bool _disposed = false;
  int _lastBoundaryAtMs = -1;

  int _sequence = 0;
  int _sentences = 0;
  int _gen = 0;

  _MtJob? _inFlight;
  final Queue<_MtJob> _finals = Queue<_MtJob>();
  _MtJob? _draftJob;
  Completer<void>? _idle;

  String get _currentKey => 's$_sequence';

  String get _globalText => _segments.map((_AsrSegment s) => s.effective).join();

  bool get isRunning => _started && !_disposed && !_stopping;

  /// 开始连续同传。返回 false 表示当前端口不支持（页面应提示并留在原模式）。
  bool start() {
    if (_started || _disposed) {
      return false;
    }
    _started = true;
    _segmenter.reset();
    if (!_openSession()) {
      _close('语音后端不支持连续同传（缺少中间识别结果）');
      return false;
    }
    onStatus?.call('同传中 · 正在听…');
    return true;
  }

  /// 每块录音 PCM 与它的音量一起送进来。ms 由字节数换算，保证时钟确定。
  void addAudio(Uint8List chunk, double level) {
    if (!isRunning) {
      return;
    }
    final int ms = chunk.lengthInBytes ~/ 32;
    if (ms > 0) {
      _segmentAudioMs += ms;
      _flush(_segmenter.onAudio(audioMs: ms, level: level));
    }
    final LiveAsrSession? session = _session;
    if (session != null) {
      try {
        session.add(chunk);
      } on Object catch (error) {
        final _AsrSegment? segment = _current;
        if (segment != null) {
          _onFailure(segment, error);
        }
      }
    }
    _maybeRotate();
  }

  /// 用户点停止：收尾当前会话、提交最后一句、等所有定稿翻译落地。
  Future<void> stop() async {
    if (_disposed || _stopping) {
      return;
    }
    _stopping = true;
    _draftJob = null;
    onStatus?.call('正在收尾…');

    final LiveAsrSession? session = _session;
    _session = null;
    if (session != null) {
      try {
        final String finalText = await session.finish();
        final _AsrSegment? segment = _current;
        if (segment != null &&
            finalText.isNotEmpty &&
            finalText.length > segment.text.length) {
          segment.finalText = finalText;
          _flush(_segmenter.onText(_globalText));
        }
      } on Object catch (error) {
        onStatus?.call('识别收尾失败：${_brief(error)}');
      }
    }
    _flush(_segmenter.finishSentence());
    await _waitFinals();

    _disposed = true;
    _idle = null;
    onStatus?.call('同传已停止');
    onClosed?.call('');
  }

  /// 取消（上滑 / 切后台 / 页面销毁）：不发结束帧、不再翻译。
  Future<void> cancel() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _gen += 1;
    _finals.clear();
    _draftJob = null;
    _inFlight = null;
    _idle?.complete();
    _idle = null;
    final LiveAsrSession? session = _session;
    _session = null;
    if (session != null) {
      await _cancelQuietly(session);
    }
  }

  bool _openSession() {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final LiveAsrSession session = openSession(direction.source);
        if (session is! PartialAsrSession) {
          unawaited(_cancelQuietly(session));
          return false;
        }
        final _AsrSegment segment = _AsrSegment(_nextSegment);
        _nextSegment += 1;
        _segments.add(segment);
        _session = session;
        _current = segment;
        _segmentAudioMs = 0;
        final PartialAsrSession partial = session as PartialAsrSession;
        partial.setPartialListener(
          (String text) => _onPartial(segment, text),
        );
        partial.setDoneListener(() => _onDone(segment));
        partial.setFailureListener(
          (Object error) => _onFailure(segment, error),
        );
        return true;
      } on Object catch (error) {
        onStatus?.call('识别连接失败，重试中：${_brief(error)}');
      }
    }
    return false;
  }

  void _onPartial(_AsrSegment segment, String text) {
    if (_disposed || _stopping || segment.index != _current?.index) {
      return;
    }
    if (text.length >= segment.text.length) {
      segment.text = text;
    }
    _failures = 0;
    _flush(_segmenter.onText(_globalText));
  }

  void _onDone(_AsrSegment segment) {
    if (_disposed || _stopping || segment.index != _current?.index) {
      return;
    }
    onStatus?.call('识别会话结束，继续听…');
    _flush(_segmenter.finishSentence());
    _rotate(commit: false);
  }

  void _onFailure(_AsrSegment segment, Object error) {
    if (_disposed || _stopping || segment.index != _current?.index) {
      return;
    }
    _failures += 1;
    if (_failures >= maxSessionFailures) {
      _close('识别连接反复失败：${_brief(error)}');
      return;
    }
    onStatus?.call('识别异常，正在重连：${_brief(error)}');
    _flush(_segmenter.finishSentence());
    _rotate(commit: false);
  }

  void _maybeRotate() {
    if (_rotating || _disposed || _stopping) {
      return;
    }
    if (_segmentAudioMs >= forceRotateAfterMs) {
      _rotate();
      return;
    }
    // 只在「刚刚发生句边界」时换连接：10 秒前的句号不能当成现在的停顿。
    if (_segmentAudioMs >= rotateAfterMs &&
        _segmenter.audioMs - _lastBoundaryAtMs <= 1000) {
      _rotate();
    }
  }

  void _rotate({bool commit = true}) {
    if (_rotating || _disposed || _stopping) {
      return;
    }
    _rotating = true;
    if (commit) {
      _flush(_segmenter.finishSentence());
    }
    final LiveAsrSession? old = _session;
    _session = null;
    _segmentAudioMs = 0;
    _lastBoundaryAtMs = -1;
    if (old != null) {
      unawaited(_finishQuietly(old));
    }
    if (!_openSession()) {
      _rotating = false;
      _close('识别连接重建失败');
      return;
    }
    _rotating = false;
  }

  void _flush(List<SegmentEvent> events) {
    if (_disposed) {
      return;
    }
    for (final SegmentEvent event in events) {
      switch (event.kind) {
        case SegmentEventKind.sourceDraft:
          onDraft?.call(InterpreterDraft(
            key: _currentKey,
            source: event.text,
          ));
          break;
        case SegmentEventKind.draftRequest:
          _submitDraft(_currentKey, event.text);
          break;
        case SegmentEventKind.sentence:
          _commitSentence(event.text);
          break;
      }
    }
  }

  void _commitSentence(String source) {
    final String clean = source.trim();
    if (clean.isEmpty) {
      return;
    }
    _lastBoundaryAtMs = _segmenter.audioMs;
    final String key = _currentKey;
    _sequence += 1;
    _sentences += 1;
    onSentence?.call(InterpreterSentence(
      key: key,
      source: clean,
      translation: Translation.missing,
      pending: true,
    ));
    onStatus?.call('正在翻译第 $_sentences 句…');
    _finals.add(_MtJob(
      key: key,
      source: clean,
      isFinal: true,
      gen: _gen,
    ));
    _pump();
  }

  void _submitDraft(String key, String source) {
    if (!pretranslate ||
        _stopping ||
        key != _currentKey ||
        source.trim().isEmpty) {
      return;
    }
    _draftJob = _MtJob(
      key: key,
      source: source.trim(),
      isFinal: false,
      gen: _gen,
    );
    _pump();
  }

  void _pump() {
    if (_disposed || _inFlight != null) {
      return;
    }
    _MtJob? job;
    if (_finals.isNotEmpty) {
      job = _finals.removeFirst();
    } else if (_draftJob != null) {
      job = _draftJob;
      _draftJob = null;
    }
    if (job == null) {
      _idle?.complete();
      _idle = null;
      return;
    }
    final _MtJob current = job;
    _inFlight = current;
    final int gen = current.gen;
    unawaited(Future<Translation>.sync(
      () => translator.translate(
        current.source,
        direction.source,
        direction.target,
      ),
    ).then<void>((Translation result) {
      if (_disposed || gen != _gen) {
        return;
      }
      final Translation guarded = _guard(result);
      if (current.isFinal) {
        onSentence?.call(InterpreterSentence(
          key: current.key,
          source: current.source,
          translation: guarded,
        ));
        onStatus?.call('已译 $_sentences 句');
      } else if (!_stopping && current.key == _currentKey && guarded.found) {
        // 草稿返回时句子可能又长了一截：用当前未提交文本，别把气泡缩回去。
        final String latest = _segmenter.pending.trim().isEmpty
            ? current.source
            : _segmenter.pending;
        onDraft?.call(InterpreterDraft(
          key: current.key,
          source: latest,
          translation: guarded,
        ));
      }
    }).catchError((Object error) {
      if (_disposed || gen != _gen) {
        return;
      }
      if (current.isFinal) {
        onSentence?.call(InterpreterSentence(
          key: current.key,
          source: current.source,
          translation: Translation.missing,
        ));
        onStatus?.call('第 $_sentences 句翻译失败：${_brief(error)}');
      }
    }).whenComplete(() {
      if (_disposed) {
        return;
      }
      _inFlight = null;
      _pump();
    }));
  }

  Translation _guard(Translation result) {
    if (!result.found || looksLikeTarget(result.text, direction.target)) {
      return result;
    }
    return Translation(
      text: '',
      provider: result.provider,
      found: false,
      isDemo: result.isDemo,
    );
  }

  Future<void> _waitFinals() async {
    if (_finals.isEmpty && !(_inFlight?.isFinal ?? false)) {
      return;
    }
    _idle ??= Completer<void>();
    await _idle!.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () {},
    );
  }

  Future<void> _finishQuietly(LiveAsrSession session) async {
    try {
      await session.finish();
    } on Object catch (error) {
      developer.log('旧识别会话收尾失败（已换新连接）',
          name: 'live_interpreter', error: error);
    }
  }

  Future<void> _cancelQuietly(LiveAsrSession session) async {
    try {
      await session.cancel();
    } on Object catch (error) {
      developer.log('取消识别会话失败（连接已丢弃）',
          name: 'live_interpreter', error: error);
    }
  }

  void _close(String reason) {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _gen += 1;
    _finals.clear();
    _draftJob = null;
    _idle?.complete();
    _idle = null;
    final LiveAsrSession? session = _session;
    _session = null;
    if (session != null) {
      unawaited(_cancelQuietly(session));
    }
    onClosed?.call(reason);
  }

  String _brief(Object error) {
    final String text = error.toString();
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }
}

class _AsrSegment {
  _AsrSegment(this.index);

  final int index;
  String text = '';
  String finalText = '';

  String get effective => finalText.length > text.length ? finalText : text;
}

class _MtJob {
  const _MtJob({
    required this.key,
    required this.source,
    required this.isFinal,
    required this.gen,
  });

  final String key;
  final String source;
  final bool isFinal;
  final int gen;
}
