import 'package:flutter_test/flutter_test.dart';
import 'package:rimg_video/rimg_video.dart';

void main() {
  test('fitEven keeps aspect, never upscales, rounds to even', () {
    expect(fitEven(1920, 1080, 1280), (1280, 720));
    expect(fitEven(1080, 1920, 1280), (720, 1280)); // portrait
    expect(fitEven(3840, 2160, 1280), (1280, 720));
    expect(fitEven(640, 360, 1280), (640, 360)); // no upscale
    expect(fitEven(1920, 1080, 0), (1920, 1080)); // 0 = keep
    final (w, h) = fitEven(1997, 1123, 1000);
    expect([w.isEven, h.isEven], [true, true]);
  });

  test('autoBitrate: 720p30 H.264 ~2.5 Mbps, HEVC lower, clamps fps', () {
    expect(autoBitrate(1280, 720, 30, RimgVideoCodec.h264), closeTo(2.5e6, 0.1e6));
    expect(autoBitrate(1280, 720, 30, RimgVideoCodec.hevc), lessThan(autoBitrate(1280, 720, 30, RimgVideoCodec.h264)));
    expect(autoBitrate(1280, 720, 240, RimgVideoCodec.h264), autoBitrate(1280, 720, 60, RimgVideoCodec.h264));
  });

  test('minBitrate has a floor', () {
    expect(minBitrate(160, 90), 150000);
    expect(minBitrate(1280, 720), greaterThan(150000));
  });
}
