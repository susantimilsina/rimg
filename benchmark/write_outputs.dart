// Writes every encoder's output to benchmark/out/ for quality scoring.
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:rimg/rimg.dart';

void main() {
  Directory('benchmark/out').createSync(recursive: true);
  for (final name in ['photo', 'horizon']) {
    final src = File('testdata/${name}_12mp.jpg').readAsBytesSync();
    for (final side in [1920, 0]) {
      final tag = side == 0 ? 'full' : '$side';
      void w(String f, List<int> b) => File('benchmark/out/${name}_${tag}_$f').writeAsBytesSync(b);
      for (final e in RimgEffort.values) {
        w('rust_${e.name}_q80.jpg', Rimg.compress(src, maxWidth: side, maxHeight: side, quality: 80, effort: e).bytes);
      }
      w('rust_balanced_q70.jpg', Rimg.compress(src, maxWidth: side, maxHeight: side, quality: 70).bytes);
      w('rust_webp_q80.webp', Rimg.compress(src, maxWidth: side, maxHeight: side, format: RimgFormat.webp).bytes);
      if (side != 0) w('rust_avif_q70.avif', Rimg.compress(src, maxWidth: side, maxHeight: side, format: RimgFormat.avif, quality: 70).bytes);
      var im = img.decodeImage(src)!;
      if (side != 0) im = img.copyResize(im, width: side, interpolation: img.Interpolation.cubic);
      w('dart_q80.jpg', img.encodeJpg(im, quality: 80));
    }
  }
}
