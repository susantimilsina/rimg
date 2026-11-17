// Raw FFI bindings to the Rust core in ../../rust/src/lib.rs.
// The native library is built and bundled by hook/build.dart.
@DefaultAsset('package:rimg/src/rimg_bindings.dart')
library;

import 'dart:ffi';

final class RimgOptions extends Struct {
  @Uint32()
  external int maxWidth;
  @Uint32()
  external int maxHeight;
  @Uint32()
  external int format;
  @Uint32()
  external int quality;
  @Uint64()
  external int targetBytes;
  @Uint32()
  external int avifSpeed;
  @Uint32()
  external int effort;
}

final class RimgResult extends Struct {
  external Pointer<Uint8> data;
  @Size()
  external int len;
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int quality;
  external Pointer<Char> error;
}

@Native<RimgResult Function(Pointer<Uint8>, Size, Pointer<RimgOptions>)>()
external RimgResult rimg_compress(
  Pointer<Uint8> input,
  int len,
  Pointer<RimgOptions> opts,
);

@Native<Void Function(RimgResult)>()
external void rimg_free(RimgResult result);

@Native<Bool Function()>()
external bool rimg_heic_supported();

@Native<Bool Function()>()
external bool rimg_avif_supported();
