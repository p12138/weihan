// 语音翻译三环编排：语音 → 文字（ASR）→ 译文（MT）→ 语音（TTS）。
// 只依赖端口，不发网络、不碰平台插件，便于用假实现做单元测试。

import 'dart:typed_data';

import 'conversation.dart';
import 'xfyun_speech.dart' show SpeechException;

/// 一轮语音对话的结果。
class SpeechTurn {
  SpeechTurn({
    required this.heard,
    required this.translation,
    required this.audio,
  });

  /// 识别出来的原文。
  final String heard;

  /// 文字翻译结果。
  final Translation translation;

  /// 译文的音频字节（mp3）；翻译失败时为空。
  final Uint8List audio;

  bool get hasAudio => audio.isNotEmpty;
}

class SpeechPipeline {
  const SpeechPipeline({
    required this.speech,
    required this.translator,
  });

  final SpeechPort speech;
  final Translator translator;

  Future<SpeechTurn> run(
    Uint8List audio,
    TranslationDirection direction,
  ) async {
    final String heard = (await speech.listen(audio, direction.source)).trim();
    if (heard.isEmpty) {
      throw const SpeechException('没有识别到语音，请靠近麦克风再试');
    }
    final Translation result = await translator.translate(
      heard,
      direction.source,
      direction.target,
    );
    final Uint8List spoken = result.found
        ? await speech.speak(result.text, direction.target)
        : Uint8List(0);
    return SpeechTurn(heard: heard, translation: result, audio: spoken);
  }
}
