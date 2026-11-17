/// Fast image compression backed by Rust (mozjpeg, libwebp, rav1e, SIMD resize).
library;

import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/rimg_bindings.dart' as b;

enum RimgFormat { jpeg, webp, avif, png }

/// JPEG encoder effort.
enum RimgEffort {
  /// mozjpeg with trellis quantisation: much smaller files, moderate speed.
  balanced,

  /// libjpeg-turbo-style encoding: fastest, larger files.
  fast,

  /// mozjpeg + scan search: slowest, a few % smaller than [balanced].
  max,
}

class RimgOutput {
  RimgOutput(this.bytes, this.width, this.height, this.quality);

  final Uint8List bytes;
  final int width;
  final int height;

  /// Quality actually used — lower than requested when [Rimg.compress]
  /// had to meet a `targetBytes` budget.
  final int quality;
}

class RimgException implements Exception {
  RimgException(this.message);
  final String message;
  @override
  String toString() => 'RimgException: $message';
}

abstract final class Rimg {
  /// Whether HEIC input is supported on this device: always on iOS/macOS,
  /// Android 11+ only, never on Windows/Linux. Check this before passing
  /// HEIC bytes if you need a fallback.
  static bool get supportsHeic => b.rimg_heic_supported();

  /// Decodes [input] (JPEG/PNG/WebP, or HEIC where [supportsHeic]), applies EXIF rotation, fits it inside
  /// [maxWidth]x[maxHeight] (never upscales), and re-encodes.
  ///
  /// If [targetBytes] is set, the result is guaranteed to be at most that
  /// size: quality is lowered first, then dimensions.
  ///
  /// Runs synchronously on the calling thread. Prefer [compressAsync] on the
  /// UI isolate.
  static RimgOutput compress(
    Uint8List input, {
    int maxWidth = 0,
    int maxHeight = 0,
    RimgFormat format = RimgFormat.jpeg,
    int quality = 80,
    int targetBytes = 0,
    int avifSpeed = 8,
    RimgEffort effort = RimgEffort.balanced,
  }) {
    final inPtr = malloc<Uint8>(input.length);
    final opts = calloc<b.RimgOptions>();
    try {
      inPtr.asTypedList(input.length).setAll(0, input);
      opts.ref
        ..maxWidth = maxWidth
        ..maxHeight = maxHeight
        ..format = format.index
        ..quality = quality
        ..targetBytes = targetBytes
        ..avifSpeed = avifSpeed
        ..effort = effort.index;
      final r = b.rimg_compress(inPtr, input.length, opts);
      try {
        if (r.error != nullptr) {
          throw RimgException(r.error.cast<Utf8>().toDartString());
        }
        return RimgOutput(
          Uint8List.fromList(r.data.asTypedList(r.len)),
          r.width,
          r.height,
          r.quality,
        );
      } finally {
        b.rimg_free(r);
      }
    } finally {
      malloc.free(inPtr);
      calloc.free(opts);
    }
  }

  /// Same as [compress] but on a background isolate, so the UI never janks.
  /// Multiple calls run in parallel on separate cores.
  static Future<RimgOutput> compressAsync(
    Uint8List input, {
    int maxWidth = 0,
    int maxHeight = 0,
    RimgFormat format = RimgFormat.jpeg,
    int quality = 80,
    int targetBytes = 0,
    int avifSpeed = 8,
    RimgEffort effort = RimgEffort.balanced,
  }) =>
      Isolate.run(
        () => compress(
          input,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          format: format,
          quality: quality,
          targetBytes: targetBytes,
          avifSpeed: avifSpeed,
          effort: effort,
        ),
      );
}
