// 真机录音与播放。抽象端口让 widget 测试可以注入假实现，不触碰平台通道。
//
// 录音格式固定 16k / 16bit / 单声道 PCM，与讯飞 ASR 接口要求一致；
// 播放写系统临时目录后用 audioplayers 播 mp3（讯飞 TTS 的 aue=lame）。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

abstract class AudioPort {
  Future<bool> hasPermission();

  Future<void> startRecord();

  Future<Uint8List> stopRecord();

  Future<void> play(Uint8List audio);
}

class DeviceAudioPort implements AudioPort {
  DeviceAudioPort({AudioRecorder? recorder, AudioPlayer? player})
      : _recorder = recorder ?? AudioRecorder(),
        _player = player ?? AudioPlayer();

  final AudioRecorder _recorder;
  final AudioPlayer _player;
  final List<String> _errors = <String>[];

  StreamSubscription<Uint8List>? _subscription;
  BytesBuilder? _buffer;

  /// 录音流偶发错误的摘要，供界面提示（不含音频内容）。
  List<String> get errors => List<String>.unmodifiable(_errors);

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> startRecord() async {
    final Stream<Uint8List> stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    final BytesBuilder buffer = BytesBuilder(copy: false);
    _buffer = buffer;
    _subscription = stream.listen(
      buffer.add,
      onError: (Object error) {
        _errors.add(error.toString());
      },
      cancelOnError: true,
    );
  }

  @override
  Future<Uint8List> stopRecord() async {
    await _recorder.stop();
    final StreamSubscription<Uint8List>? subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
    final BytesBuilder? buffer = _buffer;
    _buffer = null;
    return buffer == null ? Uint8List(0) : buffer.takeBytes();
  }

  @override
  Future<void> play(Uint8List audio) async {
    if (audio.isEmpty) {
      return;
    }
    final Directory directory =
        await Directory.systemTemp.createTemp('weihan_tts_');
    final File file =
        File('${directory.path}${Platform.pathSeparator}speech.mp3');
    await file.writeAsBytes(audio, flush: true);
    await _player.play(DeviceFileSource(file.path));
  }
}
