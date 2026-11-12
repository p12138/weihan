// 「边录边传」的可选能力接口。
//
// 为什么单独开一份接口，而不是给 SpeechPort / AudioPort 直接加抽象成员：
// 那两个类在 widget 测试里有若干 implements 替身，加成员会把它们全打断。
// 这里用 `is` 做能力探测 —— 真机实现额外 implements，老链路与所有测试替身
// 原样不动；能力缺失时页面自动退回「录完再传」，行为完全不变。

import 'dart:async';
import 'dart:typed_data';

import 'conversation.dart';

/// 一次「边录边传」的识别会话。
///
/// 生命周期：按下说话时 [LiveSpeechPort.openLiveAsr] 立刻建会话（不阻塞开录），
/// 录音过程中每来一块 PCM 就 [add]，松手 [finish]，上滑取消 [cancel]。
abstract class LiveAsrSession {
  /// 录音过程中实时送来的 PCM 增量块（16k / 16bit / 单声道）。
  void add(Uint8List pcm);

  /// 松手：把剩余音频发完、补结束帧，等云端返回最终文字。
  Future<String> finish();

  /// 上滑取消 / 启动失败：立刻丢弃，不发结束帧、不等云端。
  Future<void> cancel();
}

/// 语音端口的可选能力：支持在录音的同时上传音频。
abstract class LiveSpeechPort {
  /// **立刻**返回会话对象，建连在会话内部异步进行。
  ///
  /// 刻意不是 Future：按下说话那一瞬间必须先开录，若等 TLS 握手完成再
  /// startRecord，用户开口的前几个字会整段丢掉。
  LiveAsrSession openLiveAsr(Language language);
}

/// 音频端口的可选能力：能把录音的 PCM 增量块实时交出来。
abstract class ChunkedAudioPort {
  /// broadcast 流，页面在 startRecord 之前订阅，不会漏掉开头几帧。
  Stream<Uint8List> get pcmChunks;
}
