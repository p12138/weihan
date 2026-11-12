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
import 'live_asr.dart';
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

  /// [session] 为「边录边传」的识别会话；为空时仍走「录完再传」老路。
  ///
  /// [onHeard] / [onText] 是**低延迟回调**：识别一有结果、译文一返回就先
  /// 交给页面上屏，合成与朗读在回调之后继续跑。用户看到文字的时间从此不再
  /// 包含 TTS 那一两秒；朗读失败也只降级成提示，不会吞掉文字。
  Future<SpeechTurn> run(
    Uint8List audio,
    TranslationDirection direction, {
    LiveAsrSession? session,
    void Function(String heard)? onHeard,
    void Function(String heard, Translation translation)? onText,
  }) async {
    final String heard = await _hear(audio, direction.source, session);
    onHeard?.call(heard);
    final Translation result = await translator.translate(
      heard,
      direction.source,
      direction.target,
    );
    onText?.call(heard, result);
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

  /// 边录边传优先；会话没连上、或云端一个字都没回时，拿完整 PCM 重跑老路。
  ///
  /// 这条兜底很要紧：真机网络千差万别，新链路万一丢了前几个字，用户最多
  /// 多等一次上传，而绝不会又遇到「说完了却识别不到声音」。老路内部对空
  /// 识别有带音频时长的诊断文案，会原样冒到界面上。
  Future<String> _hear(
    Uint8List audio,
    Language source,
    LiveAsrSession? session,
  ) async {
    if (session != null) {
      try {
        final String live = (await session.finish()).trim();
        if (live.isNotEmpty) {
          return live;
        }
      } on Object catch (_) {
        // 不把失败原因写进 lastDiagnostic：老路会自己写更准确的诊断，
        // 覆盖掉反而让界面提示变模糊。
      }
    }
    final String heard = (await speech.listen(audio, source)).trim();
    if (heard.isEmpty) {
      throw const SpeechException('没有识别到语音，请靠近麦克风再试');
    }
    return heard;
  }
}
