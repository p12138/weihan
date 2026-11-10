// 默认语音端口：每次调用都按当前设置重建真实实现。
// 设置页保存讯飞凭证后立刻生效，无需重建页面，也无需重新出包。

import 'dart:typed_data';

import 'conversation.dart';
import 'speech_config.dart';
import 'xfyun_speech.dart';

class ConfigurableSpeechPort implements SpeechPort {
  const ConfigurableSpeechPort();

  @override
  bool get isAvailable => speechConfig.hasConfig;

  @override
  Future<String> listen(Uint8List audio, Language language) =>
      XfyunSpeechPort(config: speechConfig).listen(audio, language);

  @override
  Future<Uint8List> speak(String text, Language language) =>
      XfyunSpeechPort(config: speechConfig).speak(text, language);
}
