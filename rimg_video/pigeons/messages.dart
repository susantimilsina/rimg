// Pigeon definition of the Dart <-> native API. Regenerate with:
//   dart run pigeon --input pigeons/messages.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/dev/rimg/rimg_video/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.rimg.rimg_video', errorClassName: 'RimgVideoError'),
    swiftOut: 'ios/rimg_video/Sources/rimg_video/Messages.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'RimgVideoError'),
  ),
)
enum VideoCodecMsg { h264, hevc }

/// What the native side knows about an input video.
class VideoInfoMsg {
  VideoInfoMsg({
    required this.width,
    required this.height,
    required this.rotation,
    required this.durationMs,
    required this.bitrate,
    required this.frameRate,
    required this.videoCodec,
    required this.hasAudio,
    required this.audioBitrate,
    required this.isHdr,
    required this.fileBytes,
  });

  /// Stored (encoded) size, before applying [rotation].
  int width;
  int height;

  /// Clockwise display rotation in degrees: 0, 90, 180 or 270.
  int rotation;
  int durationMs;

  /// Average total bitrate (bits/s), 0 if unknown.
  int bitrate;
  double frameRate;

  /// e.g. "avc1"/"video/avc", "hvc1"/"video/hevc"; empty if unknown.
  String videoCodec;
  bool hasAudio;

  /// Audio bits/s, 0 if unknown or no audio.
  int audioBitrate;
  bool isHdr;
  int fileBytes;
}

class VideoRequestMsg {
  VideoRequestMsg({
    required this.jobId,
    required this.inputPath,
    required this.outputPath,
    required this.width,
    required this.height,
    required this.videoBitrate,
    required this.codec,
    required this.maxFps,
    required this.constantBitrate,
  });

  String jobId;
  String inputPath;
  String outputPath;

  /// Output size in display orientation (already even, already fitted).
  int width;
  int height;
  int videoBitrate;
  VideoCodecMsg codec;

  /// Drop frames above this rate; 0 = keep.
  int maxFps;

  /// Ask the encoder for CBR (used for target-size mode, where overshoot matters).
  bool constantBitrate;
}

class VideoResultMsg {
  VideoResultMsg({
    required this.width,
    required this.height,
    required this.durationMs,
    required this.fileBytes,
    required this.videoCodec,
  });

  int width;
  int height;
  int durationMs;
  int fileBytes;

  /// Codec actually used (H.264 if the device can't encode HEVC at this size).
  VideoCodecMsg videoCodec;
}

@HostApi()
abstract class RimgVideoHostApi {
  @async
  VideoInfoMsg probe(String path);

  /// Errors use codes: "cancelled", "input" (unreadable/unsupported), "encoder", "io".
  @async
  VideoResultMsg compress(VideoRequestMsg request);

  void cancel(String jobId);
}

@FlutterApi()
abstract class RimgVideoFlutterApi {
  void onProgress(String jobId, double progress);
}
