// dart run benchmark/bench.dart
// Compares rimg (Rust) with the pure-Dart `image` package on 12 MP photos.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:rimg/rimg.dart';

const runs = 5;

typedef Result = ({Duration time, int bytes});

Result bench(Result Function() f) {
  f(); // warm-up
  final times = <Duration>[];
  late int bytes;
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    bytes = f().bytes;
    times.add(sw.elapsed);
  }
  times.sort();
  return (time: times[runs ~/ 2], bytes: bytes); // median
}

// ---- pure Dart `image` package (what image_compression / downsize use)
int dartJpeg(Uint8List src, int maxSide, int q) {
  var im = img.bakeOrientation(img.decodeImage(src)!);
  if (maxSide > 0 && (im.width > maxSide || im.height > maxSide)) {
    im = im.width >= im.height
        ? img.copyResize(im, width: maxSide, interpolation: img.Interpolation.cubic)
        : img.copyResize(im, height: maxSide, interpolation: img.Interpolation.cubic);
  }
  return img.encodeJpg(im, quality: q).length;
}

int dartPng(Uint8List src, int maxSide) {
  var im = img.decodeImage(src)!;
  if (maxSide > 0) im = img.copyResize(im, width: maxSide, interpolation: img.Interpolation.cubic);
  return img.encodePng(im, level: 9).length;
}

String ms(Duration d) => '${(d.inMicroseconds / 1000).toStringAsFixed(0).padLeft(6)} ms';
String kb(int b) => '${(b / 1024).toStringAsFixed(0).padLeft(6)} KB';

void row(String name, Result rust, Result? dart) {
  final speed = dart == null ? '' : '${(dart.time.inMicroseconds / rust.time.inMicroseconds).toStringAsFixed(1).padLeft(5)}x';
  print('${name.padRight(38)} rust ${ms(rust.time)} ${kb(rust.bytes)}   '
      '${dart == null ? ''.padRight(28) : 'dart ${ms(dart.time)} ${kb(dart.bytes)}'}  $speed');
}

Future<void> main() async {
  final photo = File('testdata/photo_12mp.jpg').readAsBytesSync();
  final horizon = File('testdata/horizon_12mp.jpg').readAsBytesSync();
  final graphic = File('testdata/graphic_3mp.png').readAsBytesSync();

  print('Inputs: 4032x3024 JPEG ${kb(photo.length)}, ${kb(horizon.length)}; 2048x1536 PNG ${kb(graphic.length)}');
  print('Median of $runs runs, single thread, ${Platform.localHostname.isEmpty ? '' : ''}${Platform.operatingSystem} ${Platform.numberOfProcessors} cores\n');

  for (final (label, src) in [('photo', photo), ('horizon', horizon)]) {
    print('--- $label (12 MP JPEG)');
    row('upload 1920px JPEG q80',
        bench(() => (time: Duration.zero, bytes: Rimg.compress(src, maxWidth: 1920, maxHeight: 1920, quality: 80).bytes.length)),
        bench(() => (time: Duration.zero, bytes: dartJpeg(src, 1920, 80))));
    row('upload 1920px JPEG q80 effort=fast',
        bench(() => (time: Duration.zero, bytes: Rimg.compress(src, maxWidth: 1920, maxHeight: 1920, quality: 80, effort: RimgEffort.fast).bytes.length)),
        null);
    row('thumbnail 512px JPEG q75',
        bench(() => (time: Duration.zero, bytes: Rimg.compress(src, maxWidth: 512, maxHeight: 512, quality: 75).bytes.length)),
        bench(() => (time: Duration.zero, bytes: dartJpeg(src, 512, 75))));
    row('full-res recompress JPEG q80',
        bench(() => (time: Duration.zero, bytes: Rimg.compress(src, quality: 80).bytes.length)),
        bench(() => (time: Duration.zero, bytes: dartJpeg(src, 0, 80))));
    row('upload 1920px WebP q80',
        bench(() => (time: Duration.zero, bytes: Rimg.compress(src, maxWidth: 1920, maxHeight: 1920, format: RimgFormat.webp).bytes.length)),
        null); // `image` has no WebP encoder
    row('upload 1920px AVIF q70 speed 8',
        bench(() => (time: Duration.zero, bytes: Rimg.compress(src, maxWidth: 1920, maxHeight: 1920, format: RimgFormat.avif, quality: 70).bytes.length)),
        null);
    row('1920px JPEG, fit under 200 KB',
        bench(() => (time: Duration.zero, bytes: Rimg.compress(src, maxWidth: 1920, maxHeight: 1920, quality: 90, targetBytes: 200 * 1024).bytes.length)),
        null);
    print('');
  }

  print('--- graphic (3 MP PNG)');
  row('PNG -> 1024px PNG',
      bench(() => (time: Duration.zero, bytes: Rimg.compress(graphic, maxWidth: 1024, maxHeight: 1024, format: RimgFormat.png).bytes.length)),
      bench(() => (time: Duration.zero, bytes: dartPng(graphic, 1024))));
  row('PNG -> 1024px WebP q85',
      bench(() => (time: Duration.zero, bytes: Rimg.compress(graphic, maxWidth: 1024, maxHeight: 1024, format: RimgFormat.webp, quality: 85).bytes.length)),
      null);

  // ---- batch: 12 photos at once, one isolate each (e.g. multi-select upload)
  print('\n--- batch: 12 x 12 MP photos -> 1920px JPEG q80, parallel isolates');
  final batch = List.generate(12, (i) => i.isEven ? photo : horizon);
  Future<Duration> timeBatch(Future<void> Function(Uint8List) f) async {
    await Future.wait(batch.take(2).map(f)); // warm-up
    final sw = Stopwatch()..start();
    await Future.wait(batch.map(f));
    return sw.elapsed;
  }

  final rustBatch = await timeBatch((s) => Rimg.compressAsync(s, maxWidth: 1920, maxHeight: 1920));
  final dartBatch = await timeBatch((s) => Isolate.run(() => dartJpeg(s, 1920, 80)));
  print('rust ${ms(rustBatch)}   dart ${ms(dartBatch)}   '
      '${(dartBatch.inMicroseconds / rustBatch.inMicroseconds).toStringAsFixed(1)}x');
}
