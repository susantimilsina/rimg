import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:rimg/rimg.dart';
void main() {
  for (final n in ['photo', 'horizon']) {
    final src = File('testdata/${n}_12mp.jpg').readAsBytesSync();
    final dartImg = img.decodeImage(src)!;
    for (final q in [40, 50, 60, 70, 80, 90]) {
      void w(String e, String ext, List<int> b) => File('benchmark/sweep/${n}__${e}__$q.$ext').writeAsBytesSync(b);
      w('rust-balanced', 'jpg', Rimg.compress(src, quality: q).bytes);
      w('rust-fast', 'jpg', Rimg.compress(src, quality: q, effort: RimgEffort.fast).bytes);
      w('rust-webp', 'webp', Rimg.compress(src, quality: q, format: RimgFormat.webp).bytes);
      w('dart-image', 'jpg', img.encodeJpg(dartImg, quality: q));
    }
  }
}
