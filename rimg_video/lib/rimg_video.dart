/// Video compression for Flutter using the phone's hardware encoder
/// (AVFoundation on iOS, Media3 Transformer on Android).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'src/messages.g.dart';

enum RimgVideoCodec {
  /// Plays everywhere (browsers, old Android). Default.
  h264,

  /// ~30–40% smaller at the same quality; some older players can't play it.
  hevc,
}

class RimgVideoInfo {
  RimgVideoInfo._(VideoInfoMsg m)
    : width = m.width,
      height = m.height,
      rotation = m.rotation,
      duration = Duration(milliseconds: m.durationMs),
      bitrate = m.bitrate,
      frameRate = m.frameRate,
      videoCodec = m.videoCodec,
      hasAudio = m.hasAudio,
      audioBitrate = m.audioBitrate,
      isHdr = m.isHdr,
      fileBytes = m.fileBytes;

  /// Stored size; use [displayWidth]/[displayHeight] for what the viewer sees.
  final int width, height;

  /// Clockwise rotation in degrees (0, 90, 180, 270).
  final int rotation;
  final Duration duration;

  /// Average total bitrate in bits/s (0 if unknown).
  final int bitrate;
  final double frameRate;
  final String videoCodec;
  final bool hasAudio;

  /// Audio bits/s (0 if unknown or no audio).
  final int audioBitrate;
  final bool isHdr;
  final int fileBytes;

  bool get _sideways => rotation % 180 != 0;
  int get displayWidth => _sideways ? height : width;
  int get displayHeight => _sideways ? width : height;

  @override
  String toString() =>
      'RimgVideoInfo(${displayWidth}x$displayHeight, rot $rotation, ${duration.inMilliseconds} ms, '
      '${(bitrate / 1e6).toStringAsFixed(2)} Mbps, ${frameRate.toStringAsFixed(1)} fps, '
      '$videoCodec, audio: $hasAudio, hdr: $isHdr, $fileBytes B)';
}

class RimgVideoOutput {
  RimgVideoOutput({
    required this.path,
    required this.width,
    required this.height,
    required this.duration,
    required this.fileBytes,
    required this.reencoded,
    required this.codec,
  });

  final String path;

  /// Display size of the output.
  final int width, height;
  final Duration duration;
  final int fileBytes;

  /// False when the input was already small enough and was just copied.
  final bool reencoded;

  /// Codec of the output. HEVC requests fall back to H.264 on devices that
  /// can't encode HEVC at the requested size; null when the input was copied.
  final RimgVideoCodec? codec;

  @override
  String toString() =>
      'RimgVideoOutput(${width}x$height, ${duration.inMilliseconds} ms, $fileBytes B, reencoded: $reencoded, codec: ${codec?.name})';
}

class RimgVideoException implements Exception {
  RimgVideoException(this.code, this.message);

  /// "cancelled", "input" (unreadable or unsupported file), "encoder", "io".
  final String code;
  final String message;

  bool get isCancelled => code == 'cancelled';

  @override
  String toString() => 'RimgVideoException($code): $message';
}

/// A running compression. Listen to [progress] (0..1), await [result], or [cancel].
class RimgVideoJob {
  RimgVideoJob._(this._id);

  final String _id;
  final _progress = StreamController<double>.broadcast();
  final _result = Completer<RimgVideoOutput>();
  bool _cancelled = false;

  Stream<double> get progress => _progress.stream;
  Future<RimgVideoOutput> get result => _result.future;

  /// Stops the encode and deletes the partial output. [result] then fails
  /// with a [RimgVideoException] whose [RimgVideoException.isCancelled] is true.
  Future<void> cancel() async {
    _cancelled = true;
    await RimgVideo._api.cancel(_id);
  }
}

abstract final class RimgVideo {
  static final _api = RimgVideoHostApi();
  static final _jobs = <String, RimgVideoJob>{};
  static int _nextId = 0;
  static bool _listening = false;

  /// Reads size, duration, bitrate, rotation, codec, HDR and audio info.
  static Future<RimgVideoInfo> probe(String path) async {
    try {
      return RimgVideoInfo._(await _api.probe(path));
    } on Exception catch (e) {
      throw _wrap(e);
    }
  }

  /// Compresses [inputPath] into an MP4 at [outputPath].
  ///
  /// * [maxSize]: longest edge of the output in pixels (never upscales); 0 keeps the size.
  /// * [bitrate]: video bits/s; 0 picks one from the output size and frame rate.
  /// * [targetBytes]: if > 0, aim for a file of at most this size (overrides [bitrate]).
  /// * [maxFps]: drop frames above this rate (slo-mo keeps its timing); 0 keeps all.
  /// * [skipIfSmaller]: if the input is already within these limits, SDR and
  ///   H.264/HEVC, copy it instead of re-encoding.
  ///
  /// HDR input (e.g. iPhone 10-bit HDR) is converted to normal SDR colours.
  /// Rotation is applied. Audio is kept.
  static RimgVideoJob compress({
    required String inputPath,
    required String outputPath,
    int maxSize = 1280,
    int bitrate = 0,
    int targetBytes = 0,
    RimgVideoCodec codec = RimgVideoCodec.h264,
    int maxFps = 30,
    bool skipIfSmaller = true,
  }) {
    _ensureListening();
    final job = RimgVideoJob._('job${_nextId++}');
    _jobs[job._id] = job;
    _run(
          job,
          inputPath,
          outputPath,
          maxSize,
          bitrate,
          targetBytes,
          codec,
          maxFps,
          skipIfSmaller,
        )
        .then(
          job._result.complete,
          onError: (Object e, StackTrace s) =>
              job._result.completeError(e is Exception ? _wrap(e) : e, s),
        )
        .whenComplete(() {
          _jobs.remove(job._id);
          job._progress.close();
        });
    return job;
  }

  static Future<RimgVideoOutput> _run(
    RimgVideoJob job,
    String input,
    String output,
    int maxSize,
    int bitrate,
    int targetBytes,
    RimgVideoCodec codec,
    int maxFps,
    bool skipIfSmaller,
  ) async {
    final info = await probe(input);
    final (w, h) = fitEven(info.displayWidth, info.displayHeight, maxSize);
    final fps = maxFps > 0
        ? math.min(info.frameRate, maxFps.toDouble())
        : info.frameRate;
    // Audio is copied through untouched, so budget its real bitrate.
    final audioBps = !info.hasAudio
        ? 0
        : (info.audioBitrate > 0 ? info.audioBitrate : 128000);
    final durationS = info.duration.inMilliseconds / 1000;

    var videoBps = bitrate > 0 ? bitrate : autoBitrate(w, h, fps, codec);
    if (targetBytes > 0 && durationS > 0) {
      // 4% container overhead; never go below a watchable floor.
      final budget = (targetBytes * 8 * 0.96 / durationS - audioBps).round();
      videoBps = math.max(budget, minBitrate(w, h));
    }

    // Re-encoding is required for HDR, resizing, frame dropping or an unusual codec/container.
    final lower = input.toLowerCase();
    final needsWork =
        info.isHdr ||
        info.displayWidth > w ||
        info.displayHeight > h ||
        (maxFps > 0 && info.frameRate > maxFps + 1) ||
        !(info.videoCodec.contains('avc') ||
            info.videoCodec.contains('hev') ||
            info.videoCodec.contains('hvc')) ||
        !(lower.endsWith('.mp4') ||
            lower.endsWith('.mov') ||
            lower.endsWith('.m4v'));
    final inputVideoBps = info.bitrate - audioBps;
    final smallEnough = targetBytes > 0
        ? info.fileBytes <= targetBytes
        : inputVideoBps > 0 && inputVideoBps <= videoBps * 1.25;

    Future<RimgVideoOutput> copyInput() async {
      await File(input).copy(output);
      job._progress.add(1);
      return RimgVideoOutput(
        path: output,
        width: info.displayWidth,
        height: info.displayHeight,
        duration: info.duration,
        fileBytes: info.fileBytes,
        reencoded: false,
        codec: null,
      );
    }

    if (skipIfSmaller && !needsWork && smallEnough) return copyInput();

    Future<VideoResultMsg> encode(int vbps) {
      if (job._cancelled) throw RimgVideoException('cancelled', 'cancelled');
      return _api.compress(
        VideoRequestMsg(
          jobId: job._id,
          inputPath: input,
          outputPath: output,
          width: w,
          height: h,
          videoBitrate: vbps,
          codec: VideoCodecMsg.values[codec.index],
          maxFps: maxFps,
          constantBitrate: targetBytes > 0,
        ),
      );
    }

    var r = await encode(videoBps);
    // Hardware encoders overshoot sometimes; one corrective pass if >10% over.
    if (targetBytes > 0 &&
        r.fileBytes > targetBytes * 1.1 &&
        videoBps > minBitrate(w, h)) {
      // Scale only the video part; audio size is fixed.
      final audioBytes = audioBps * durationS / 8;
      final scaled =
          (videoBps *
                  (targetBytes * 0.96 - audioBytes) /
                  math.max(1, r.fileBytes - audioBytes))
              .round();
      r = await encode(math.max(scaled, minBitrate(w, h)));
    }
    // Never hand back a bigger file than we were given when nothing had to change.
    if (skipIfSmaller && !needsWork && r.fileBytes >= info.fileBytes) {
      return copyInput();
    }
    return RimgVideoOutput(
      path: output,
      width: r.width,
      height: r.height,
      duration: Duration(milliseconds: r.durationMs),
      fileBytes: r.fileBytes,
      reencoded: true,
      codec: RimgVideoCodec.values[r.videoCodec.index],
    );
  }

  static void _ensureListening() {
    if (_listening) return;
    _listening = true;
    RimgVideoFlutterApi.setUp(_ProgressSink());
  }

  static RimgVideoException _wrap(Exception e) {
    if (e is RimgVideoException) return e;
    // Pigeon surfaces native errors as PlatformException(code, message).
    final dynamic d = e;
    try {
      return RimgVideoException(d.code as String, (d.message as String?) ?? '');
    } catch (_) {
      return RimgVideoException('io', e.toString());
    }
  }
}

class _ProgressSink implements RimgVideoFlutterApi {
  @override
  void onProgress(String jobId, double progress) {
    final job = RimgVideo._jobs[jobId];
    if (job != null && !job._progress.isClosed) {
      job._progress.add(progress.clamp(0, 1));
    }
  }
}

/// Fits [w]x[h] inside a [maxSize] box (longest edge), never upscaling,
/// rounded to even numbers (required by H.264/HEVC 4:2:0).
(int, int) fitEven(int w, int h, int maxSize) {
  var s = 1.0;
  if (maxSize > 0 && math.max(w, h) > maxSize) s = maxSize / math.max(w, h);
  int even(double v) => math.max(2, (v / 2).round() * 2);
  return (even(w * s), even(h * s));
}

/// Bits/s for good-looking phone video: ~0.09 bits per pixel per frame for
/// H.264 (720p30 ≈ 2.5 Mbps, 1080p30 ≈ 5.6 Mbps), 35% less for HEVC.
int autoBitrate(int w, int h, double fps, RimgVideoCodec codec) {
  final f = fps.clamp(15, 60);
  final bpp = codec == RimgVideoCodec.h264 ? 0.09 : 0.06;
  return (w * h * f * bpp).round();
}

/// Lowest bitrate we allow in target-size mode before quality collapses.
int minBitrate(int w, int h) => math.max(150000, (w * h * 30 * 0.02).round());
