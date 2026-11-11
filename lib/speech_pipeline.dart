// 语音翻译三环编排：语音 → 文字（ASR）→ 译文（MT）→ 语音（TTS）。
// 只依赖端口，不发网络、不碰平台插件，便于用假实现做单元测试。
//
// 关键取舍：**朗读失败不算整轮失败**。
// 用户最需要的是听懂对方说了什么，文字本身就是结果；亚语音（TTS）只是附加。
// 早期版本把合成异常直接往外抛，结果是维语发音人没开通时，识别到的原文和
// 译文会一起消失、界面上只剩一句「语音失败」—— 这就是「说中文没有声音」
// 且连字都看不到的根因。[SpeechTurn.speakError] 把这类失败降级成提示。

import 'dart:typed_data';

import 'conversation.dart';
import 'xfyun_speech.dart' show SpeechException;

/// 一轮语音对话的结果。
class SpeechTurn {
  SpeechTurn({
    required this.heard,
    required this.translation,
    required this.audio,
    this.speakError,
  });

  /// 识别出来的原文。
  final String heard;

  /// 文字翻译结果。
  final Translation translation;

  /// 译文的音频字节（mp3）；翻译或合成失败时为空。
  final Uint8List audio;

  /// 朗读失败的原因；为空表示朗读成功，或本来就不需要朗读。
  final String? speakError;

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
    if (!result.found) {
      return SpeechTurn(
        heard: heard,
        translation: result,
        audio: Uint8List(0),
      );
    }

    Uint8List spoken = Uint8List(0);
    String? speakError;
    try {
      spoken = await speech.speak(result.text, direction.target);
      if (spoken.isEmpty) {
        speakError = '合成返回空音频（该语言发音人可能未在讯飞控制台开通）';
      }
    } on SpeechException catch (error) {
      speakError = error.message;
    } on Object catch (error) {
      speakError = error.toString();
    }
    return SpeechTurn(
      heard: heard,
      translation: result,
      audio: spoken,
      speakError: speakError,
    );
  }
}
