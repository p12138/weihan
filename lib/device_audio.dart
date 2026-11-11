// 真机录音与播放。抽象端口让 widget 测试可以注入假实现，不触碰平台通道。
//
// 录音格式固定 16k / 16bit / 单声道 PCM，与讯飞 ASR 接口要求一致；
// 播放写系统临时目录后用 audioplayers 播 mp3（讯飞 TTS 的 aue=lame）。
//
// 音量：录音时同时订阅麦克风振幅，映射成 0..1 的线性值喂给界面画波形。
// 相机/微信那种「说话时条条跳动」的效果必须有真实音量，伪造的随机数
// 一旦没在说话也在跳，用户会以为麦克风一直有输入。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

abstract class AudioPort {
  Future<bool> hasPermission();

  Future<void> startRecord();

  Future<Uint8List> stopRecord();

  Future<void> play(Uint8List audio);

  /// 录音过程中的实时音量，取值 0..1。
  ///
  /// 默认给空流：测试里的假实现不必关心波形，没有这条流时界面退化成
  /// 静默的静态条，不会报错、也不会漏掉任何帧。
  Stream<double> get levels => const Stream<double>.empty();

  /// 页面销毁时释放资源。默认什么都不做，假实现无需关心。
  void dispose() {}
}

/// 把 `record` 给出的 dBFS 值换算成 0..1。
///
/// dBFS 是负值：0 表示满幅，-60 以下基本等于安静。实测手机在安静室内
/// 约 -50 ～ -40，正常说话 -30 ～ -12，所以把 -60..0 拉成 0..1 足够用，
/// 再用 sqrt 压一下低端，让小音量也能推出可见的起伏。
double levelFromDb(double db) {
  if (db.isNaN || db.isInfinite) {
    return 0;
  }
  final double normalized = ((db + 60) / 60).clamp(0.0, 1.0).toDouble();
  return math.sqrt(normalized);
}

class DeviceAudioPort implements AudioPort {
  DeviceAudioPort({AudioRecorder? recorder, AudioPlayer? player})
      : _recorder = recorder ?? AudioRecorder(),
        _player = player ?? AudioPlayer();

  final AudioRecorder _recorder;
  final AudioPlayer _player;
  final List<String> _errors = <String>[];

  StreamSubscription<Uint8List>? _subscription;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  final StreamController<double> _levels = StreamController<double>.broadcast();
  BytesBuilder? _buffer;

  /// 播放前只配置一次音频会话：否则 iOS 静音开关打开、Android 抢不到
  /// 音频焦点时都会「明明合成了音频却一点声音没有」。
  bool _audioContextReady = false;

  /// 录音流偶发错误的摘要，供界面提示（不含音频内容）。
  List<String> get errors => List<String>.unmodifiable(_errors);

  @override
  Stream<double> get levels => _levels.stream;

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
    // 振幅是另一条独立流，与音频数据流并行；它失败不影响录音本身。
    try {
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 90))
          .listen(
        (Amplitude amplitude) {
          if (!_levels.isClosed) {
            _levels.add(levelFromDb(amplitude.current));
          }
        },
        onError: (Object error) {
          _errors.add('amplitude: $error');
        },
      );
    } on Object catch (error) {
      // 平台不支持振幅时静默降级：波形退化成静态条，录音照常。
      _errors.add('amplitude: $error');
    }
  }

  @override
  Future<Uint8List> stopRecord() async {
    await _recorder.stop();
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
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
    await _ensureAudioContext();
    final Directory directory =
        await Directory.systemTemp.createTemp('weihan_tts_');
    final File file =
        File('${directory.path}${Platform.pathSeparator}speech.mp3');
    await file.writeAsBytes(audio, flush: true);
    await _player.play(DeviceFileSource(file.path));
  }

  Future<void> _ensureAudioContext() async {
    if (_audioContextReady) {
      return;
    }
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            // 走 playback 分类：否则 iPhone 侧边静音开关一拨，TTS 就彻底没声。
            options: const <AVAudioSessionOptions>{
              AVAudioSessionOptions.defaultToSpeaker,
            },
          ),
          android: const AudioContextAndroid(
            contentType: AndroidContentType.speech,
            usageType: AndroidUsageType.assistant,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
    } on Object catch (error) {
      // 配置失败不阻塞播放：能用默认会话出声就不该因为这次调用整轮失败。
      _errors.add('audioContext: $error');
    }
    _audioContextReady = true;
  }

  /// 页面销毁时释放流控制器（否则热重载会留下一个永远关不掉的 controller）。
  @override
  void dispose() {
    _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    _subscription?.cancel();
    _subscription = null;
    if (!_levels.isClosed) {
      _levels.close();
    }
  }
}
