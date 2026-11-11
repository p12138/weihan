// 音量与录音诊断单测：波形「跳不跳」和失败提示「说得清不清楚」都钉在这里。
//
// dBFS 是负值，直接取绝对值会得到一堆十几的大数，clamp 之后永远满格；
// 反过来不压缩低端，正常说话只剩 0.2，条条几乎不动。
// 电平现在直接从录到的 PCM 块算，不再依赖平台振幅流，所以这段换算必须准。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/device_audio.dart';

/// 造一段 16bit 小端、正负交替的方波 PCM，幅度可控。
Uint8List _pcm(int amplitude, [int samples = 160]) {
  final Uint8List bytes = Uint8List(samples * 2);
  final ByteData data = ByteData.sublistView(bytes);
  for (int i = 0; i < samples; i++) {
    data.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
  }
  return bytes;
}

void main() {
  test('满幅（0 dBFS）对应 1', () {
    expect(levelFromDb(0), 1.0);
  });

  test('安静到 -60 dBFS 以下对应 0', () {
    expect(levelFromDb(-60), 0.0);
    expect(levelFromDb(-90), 0.0);
  });

  test('正常说话落在可见区间', () {
    // -30 dBFS 是常见说话音量，映射后应该在腰部偏上，而不是贴地。
    expect(levelFromDb(-30), greaterThan(0.6));
    expect(levelFromDb(-30), lessThan(1.0));
    // -45 dBFS 很轻，但仍应有可分辨的起伏。
    expect(levelFromDb(-45), greaterThan(0.3));
    expect(levelFromDb(-45), lessThan(levelFromDb(-30)));
  });

  test('非法值不抛异常，退化为 0', () {
    expect(levelFromDb(double.nan), 0.0);
    expect(levelFromDb(double.negativeInfinity), 0.0);
    expect(levelFromDb(double.infinity), 0.0);
  });

  test('单调不减', () {
    double previous = -1;
    for (int db = -80; db <= 0; db += 5) {
      final double value = levelFromDb(db.toDouble());
      expect(value, greaterThanOrEqualTo(previous));
      previous = value;
    }
  });

  test('PCM 静音 / 空块对应 0', () {
    expect(levelFromPcm(Uint8List(0)), 0.0);
    expect(levelFromPcm(Uint8List(320)), 0.0);
    // 奇数长度也不能越界或抛异常。
    expect(levelFromPcm(Uint8List(3)), 0.0);
  });

  test('PCM 满幅接近 1', () {
    expect(levelFromPcm(_pcm(32767)), greaterThan(0.95));
  });

  test('PCM 幅度越大电平越高，且真实说话音量可见', () {
    final double quiet = levelFromPcm(_pcm(100));
    final double normal = levelFromPcm(_pcm(1000));
    final double loud = levelFromPcm(_pcm(10000));
    expect(quiet, lessThan(normal));
    expect(normal, lessThan(loud));
    expect(loud, lessThanOrEqualTo(1.0));
    // 1000/32768 ≈ -30 dBFS，正是正常说话，波形该明显抬起。
    expect(normal, greaterThan(0.6));
  });

  test('录音诊断：0 字节、低电平、正常三种情况各自说清楚', () {
    expect(DeviceAudioPort.describeRecording(0, 1200, 0), contains('0 字节'));

    final String quiet = DeviceAudioPort.describeRecording(64000, 2000, 0.02);
    expect(quiet, contains('2.0s'));
    expect(quiet, contains('62.5KB'));
    expect(quiet, contains('电平极低'));

    final String ok = DeviceAudioPort.describeRecording(64000, 2000, 0.7);
    expect(ok, contains('峰值 70%'));
    expect(ok, isNot(contains('电平极低')));
  });
}
