// On-device benchmark: rimg (Rust) vs flutter_image_compress (Android
// BitmapFactory + Bitmap.compress) vs the pure-Dart `image` package.
// Run with `flutter run --profile`; results go to the screen and to logcat
// with the prefix RIMGBENCH. Sample outputs are written to the app's external
// files dir (pull with adb) for quality scoring.
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:rimg/rimg.dart';

void main() => runApp(const MaterialApp(home: BenchPage()));

// Top-level so the isolate closure only captures its own arguments.
Future<int> dartJpegAsync(Uint8List src, int side, int q) =>
    Isolate.run(() => _BenchPageState.dartJpeg(src, side, q));

class BenchPage extends StatefulWidget {
  const BenchPage({super.key});
  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> {
  final lines = <String>[];

  void log(String s) {
    // ignore: avoid_print
    print('RIMGBENCH $s');
    setState(() => lines.add(s));
    // Also persist, so results can be read from the app container (iOS simulator).
    getApplicationDocumentsDirectory().then(
        (d) => File('${d.path}/results.txt').writeAsStringSync('${lines.join('\n')}\n'));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => run());
  }

  /// Median of [n] timed runs after one warm-up. Returns (ms, bytes).
  Future<(double, int)> time(Future<int> Function() f, {int n = 5}) async {
    await f();
    final t = <double>[];
    late int bytes;
    for (var i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      bytes = await f();
      t.add(sw.elapsedMicroseconds / 1000);
    }
    t.sort();
    return (t[n ~/ 2], bytes);
  }

  Future<void> row(String label, Future<int> Function() f, {int n = 5}) async {
    final (ms, bytes) = await time(f, n: n);
    log('${label.padRight(34)} ${ms.toStringAsFixed(0).padLeft(6)} ms ${(bytes / 1024).toStringAsFixed(0).padLeft(6)} KB');
  }

  static int dartJpeg(Uint8List src, int side, int q) {
    var im = img.bakeOrientation(img.decodeImage(src)!);
    if (side > 0) im = img.copyResize(im, width: side, interpolation: img.Interpolation.cubic);
    return img.encodeJpg(im, quality: q).length;
  }

  Future<Uint8List> fic(Uint8List src, int w, int h, int q) =>
      FlutterImageCompress.compressWithList(src, minWidth: w, minHeight: h, quality: q);

  Future<void> run() async {
    final info = Platform.isAndroid ? await File('/proc/cpuinfo').readAsString().catchError((_) => '') : '';
    log('${Platform.operatingSystem} ${Platform.operatingSystemVersion} cores=${Platform.numberOfProcessors} ${RegExp(r'Hardware\s*:\s*(.*)').firstMatch(info)?.group(1) ?? ''}');

    for (final name in ['photo', 'horizon']) {
      final src = (await rootBundle.load('assets/${name}_12mp.jpg')).buffer.asUint8List();
      log('--- $name 4032x3024');
      await row('rimg 1920 q80 balanced', () async => (await Rimg.compressAsync(src, maxWidth: 1920, maxHeight: 1920)).bytes.length);
      await row('rimg 1920 q80 fast', () async => (await Rimg.compressAsync(src, maxWidth: 1920, maxHeight: 1920, effort: RimgEffort.fast)).bytes.length);
      await row('flutter_image_compress 1920 q80', () async => (await fic(src, 1920, 1440, 80)).length);
      await row('image (dart) 1920 q80', () => dartJpegAsync(src, 1920, 80), n: 3);
      await row('rimg 512 q75', () async => (await Rimg.compressAsync(src, maxWidth: 512, maxHeight: 512, quality: 75)).bytes.length);
      await row('flutter_image_compress 512 q75', () async => (await fic(src, 512, 384, 75)).length);
      await row('rimg full q80', () async => (await Rimg.compressAsync(src, quality: 80)).bytes.length);
      await row('flutter_image_compress full q80', () async => (await fic(src, 4032, 3024, 80)).length);
      await row('rimg 1920 webp q80', () async => (await Rimg.compressAsync(src, maxWidth: 1920, maxHeight: 1920, format: RimgFormat.webp)).bytes.length);
    }

    // ---- HEIC input (decoded by the OS on both sides)
    log('--- HEIC 4032x3024 (Display P3)  supportsHeic=${Rimg.supportsHeic}');
    final heic = (await rootBundle.load('assets/photo_12mp.heic')).buffer.asUint8List();
    await row('rimg heic->1920 q80 balanced', () async => (await Rimg.compressAsync(heic, maxWidth: 1920, maxHeight: 1920)).bytes.length);
    await row('rimg heic->1920 q80 fast', () async => (await Rimg.compressAsync(heic, maxWidth: 1920, maxHeight: 1920, effort: RimgEffort.fast)).bytes.length);
    await row('flutter_image_compress heic->1920', () async => (await fic(heic, 1920, 1440, 80)).length);
    await row('rimg heic->512 q75', () async => (await Rimg.compressAsync(heic, maxWidth: 512, maxHeight: 512, quality: 75)).bytes.length);
    await row('flutter_image_compress heic->512', () async => (await fic(heic, 512, 384, 75)).length);
    final rotated = (await rootBundle.load('assets/rotated.heic')).buffer.asUint8List();
    final r = await Rimg.compressAsync(rotated);
    final f = img.decodeJpg(await fic(rotated, 300, 300, 80))!;
    log('rotated.heic (stored 400x300, orientation 6): rimg ${r.width}x${r.height}  fic ${f.width}x${f.height}');
    final heicDir = Directory('${(Platform.isAndroid ? (await getExternalStorageDirectory())! : await getApplicationDocumentsDirectory()).path}/heic')
      ..createSync(recursive: true);
    File('${heicDir.path}/rimg_1920.jpg').writeAsBytesSync((await Rimg.compressAsync(heic, maxWidth: 1920, maxHeight: 1920)).bytes);
    File('${heicDir.path}/rimg_1920.webp').writeAsBytesSync((await Rimg.compressAsync(heic, maxWidth: 1920, maxHeight: 1920, format: RimgFormat.webp)).bytes);
    File('${heicDir.path}/fic_1920.jpg').writeAsBytesSync(await fic(heic, 1920, 1440, 80));
    File('${heicDir.path}/rimg_rotated.jpg').writeAsBytesSync(r.bytes);

    final photo = (await rootBundle.load('assets/photo_12mp.jpg')).buffer.asUint8List();
    final horizon = (await rootBundle.load('assets/horizon_12mp.jpg')).buffer.asUint8List();
    final batch = List.generate(12, (i) => i.isEven ? photo : horizon);
    log('--- batch 12 photos -> 1920 q80, all at once');
    await row('rimg (12 isolates)', () async {
      final r = await Future.wait(batch.map((s) => Rimg.compressAsync(s, maxWidth: 1920, maxHeight: 1920)));
      return r.fold<int>(0, (a, o) => a + o.bytes.length);
    }, n: 3);
    await row('flutter_image_compress', () async {
      final r = await Future.wait(batch.map((s) => fic(s, 1920, 1440, 80)));
      return r.fold<int>(0, (a, o) => a + o.length);
    }, n: 3);

    // Quality sweep at full resolution for size-at-equal-quality scoring.
    final base = Platform.isAndroid ? (await getExternalStorageDirectory())! : await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/sweep')..createSync(recursive: true);
    for (final (name, src) in [('photo', photo), ('horizon', horizon)]) {
      for (final q in [40, 50, 60, 70, 80, 90]) {
        File('${dir.path}/${name}__android-fic__$q.jpg').writeAsBytesSync(await fic(src, 4032, 3024, q));
        File('${dir.path}/${name}__rust-balanced__$q.jpg').writeAsBytesSync((await Rimg.compressAsync(src, quality: q)).bytes);
      }
    }
    log('sweep written to ${dir.path}');
    log('DONE');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('rimg vs flutter_image_compress')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [for (final l in lines) Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 11))],
        ),
      );
}
