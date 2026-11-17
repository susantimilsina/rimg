import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:rimg/rimg.dart';
import 'package:test/test.dart';

void main() {
  final photo = File('testdata/photo_12mp.jpg').readAsBytesSync();

  test('resizes keeping aspect ratio, output decodes', () {
    for (final f in RimgFormat.values.where((f) => f != RimgFormat.avif)) {
      final out = Rimg.compress(photo, maxWidth: 1920, maxHeight: 1920, format: f);
      expect([out.width, out.height], [1920, 1440], reason: f.name);
      final back = img.decodeImage(out.bytes)!;
      expect([back.width, back.height], [1920, 1440], reason: f.name);
    }
  });

  test('avif produces an ftyp/avif container', () {
    final out = Rimg.compress(photo, maxWidth: 800, maxHeight: 800, format: RimgFormat.avif, avifSpeed: 10);
    expect(String.fromCharCodes(out.bytes.sublist(4, 12)), 'ftypavif');
  });

  test('target size is honoured', () {
    final out = Rimg.compress(photo, maxWidth: 1920, maxHeight: 1920, quality: 95, targetBytes: 150 * 1024);
    expect(out.bytes.length, lessThanOrEqualTo(150 * 1024));
  });

  test('applies EXIF orientation', () {
    // 40x20 image tagged orientation=6 (rotate 90 CW) -> should come out 20x40.
    final src = img.Image(width: 40, height: 20);
    src.exif.imageIfd['Orientation'] = 6;
    final out = Rimg.compress(img.encodeJpg(src));
    expect([out.width, out.height], [20, 40]);
  });

  test('HEIC input (macOS: ImageIO)', () {
    expect(Rimg.supportsHeic, isTrue);
    final heic = File('testdata/photo_12mp.heic').readAsBytesSync();
    final out = Rimg.compress(heic, maxWidth: 1920, maxHeight: 1920);
    expect([out.width, out.height], [1920, 1440]);
    expect(img.decodeJpg(out.bytes), isNotNull);
    final rotated = Rimg.compress(File('testdata/rotated.heic').readAsBytesSync());
    expect([rotated.width, rotated.height], [300, 400]);
  }, testOn: 'mac-os');

  test('corrupt HEIC throws RimgException', () {
    final heic = File('testdata/rotated.heic').readAsBytesSync().sublist(0, 200);
    expect(() => Rimg.compress(heic), throwsA(isA<RimgException>()));
  });

  test('bad input throws RimgException, not a crash', () {
    expect(() => Rimg.compress(Uint8List.fromList([1, 2, 3])), throwsA(isA<RimgException>()));
  });

  test('compressAsync runs in parallel isolates', () async {
    final outs = await Future.wait(List.generate(4, (_) => Rimg.compressAsync(photo, maxWidth: 1080, maxHeight: 1080)));
    expect(outs.every((o) => o.width == 1080), isTrue);
  });
}
