# rimg — Rust image compression for Flutter/Dart (prototype)

Decode (JPEG/PNG/WebP, **HEIC** via the OS decoder) → EXIF rotate → SIMD Lanczos resize → encode
(mozjpeg JPEG, libwebp WebP, PNG, and optionally rav1e AVIF), with an optional
"fit under N bytes" mode. Colour-managed: JPEG keeps the source ICC profile
(e.g. iPhone Display P3); WebP/AVIF/PNG are converted to sRGB.

Exposed to Dart through `dart:ffi`. The Rust code is compiled automatically by
a native-assets build hook (`hook/build.dart` + `native_toolchain_rust`) for
whatever Flutter is building — no `flutter_rust_bridge`, no prebuilt binaries.

```dart
import 'package:rimg/rimg.dart';

final out  = await Rimg.compressAsync(bytes, maxWidth: 1920, maxHeight: 1920); // mozjpeg q80
final fast = await Rimg.compressAsync(bytes, maxWidth: 1920, maxHeight: 1920, effort: RimgEffort.fast);
final webp = await Rimg.compressAsync(bytes, format: RimgFormat.webp);
final avif = await Rimg.compressAsync(bytes, format: RimgFormat.avif); // only if enabled, see below
final fits = await Rimg.compressAsync(bytes, targetBytes: 200 * 1024);

// HEIC (iPhone camera default) goes through the same call:
if (Rimg.supportsHeic) await Rimg.compressAsync(heicBytes, maxWidth: 1920, maxHeight: 1920);
```

## Status

| Area | State |
|---|---|
| Image compression (JPEG / WebP / PNG, optional AVIF) | ✅ Prototype done; tested on macOS, Android emulator, iOS simulator |
| HEIC input | ✅ Done (iOS/macOS, Android 11+) |
| AVIF output | ✅ Opt-in (`avif: true`), off by default to save ~2.5 MB |
| Physical-phone testing | ⏳ Not done yet |
| **Video compression** | 📝 Planned, not started; see [docs/video-plan.md](docs/video-plan.md) (separate `rimg_video` plugin, hardware encoders) |

## AVIF output is opt-in

AVIF encoding (rav1e) adds ~2.5 MB per ABI, so it is not built by default and
`RimgFormat.avif` throws `RimgException`. To enable it, add this to **your app's** `pubspec.yaml`
and rebuild (`Rimg.supportsAvif` tells you at runtime):

```yaml
hooks:
  user_defines:
    rimg:
      avif: true
```

## HEIC

HEIC is decoded by the operating system's own (licensed, hardware-backed) decoder,
called directly from Rust — no bundled HEVC decoder, no LGPL/patent exposure, no size cost.

| Platform | Decoder | `Rimg.supportsHeic` |
|---|---|---|
| iOS / macOS | ImageIO thumbnail API (decodes at reduced size, applies orientation) | always |
| Android 11+ | NDK `AImageDecoder` (`dlopen`ed, so minSdk 24 apps still load) | API 30+ |
| Android 9–10, Windows, Linux | — | false (throws `RimgException`) |

Colour: on Apple the Display P3 profile is kept (JPEG embeds it, other formats convert to
sRGB). Android's decoder exposes no ICC bytes, so rimg converts P3 → sRGB itself
(`AImageDecoder_setDataSpace(SRGB)` was observed to be ignored for HEIF).
Not handled: HDR gain maps (SDR base image is used), multi-image HEIC (primary image only).

## Layout

| Path | What |
|---|---|
| `rust/src/lib.rs` | The engine + C ABI (`rimg_compress`, `rimg_free`, `rimg_heic_supported`) |
| `rust/src/heif/` | HEIC sniffing + `apple.rs` (ImageIO) and `android.rs` (AImageDecoder) |
| `lib/rimg.dart`, `lib/src/rimg_bindings.dart` | Dart API and `@Native` bindings |
| `hook/build.dart` | Builds the Rust crate per target; also fixes PATH when Xcode runs it |
| `test/rimg_test.dart`, `rust/src/lib.rs` tests | Formats, AVIF, target size, EXIF rotation, Display P3, bad input, parallel isolates |
| `example_app/` | Flutter benchmark app (Android + iOS): rimg vs `flutter_image_compress` vs `image` |
| `benchmark/bench.dart` | macOS speed vs the pure-Dart `image` package |
| `benchmark/sweep.dart`, `rust/examples/quality.rs`, `benchmark/rd_table.py` | Size at equal quality (SSIMULACRA2, colour-managed) |
| `benchmark/imageio.swift` | Apple ImageIO baseline |

## Run

```bash
dart test
dart run benchmark/bench.dart
cd example_app && flutter build apk --release --target-platform android-arm64   # then install + open
cd example_app && flutter build ios --simulator --debug                         # then install on a simulator
```

The app shows results on screen, logs them as `RIMGBENCH …` (logcat) and writes
`Documents/results.txt` plus a quality sweep folder.

## Results

Inputs: two 12 MP (4032×3024) JPEGs tagged Display P3, like iPhone photos.
Medians of 5 runs. "fic" = `flutter_image_compress`.

### Speed

| Task | Platform | rimg balanced | rimg `fast` | fic | `image` (Dart) |
|---|---|---|---|---|---|
| → 1920px JPEG | macOS (M5) | 53–98 ms | **34–47 ms** | 29–34 ms¹ | 389–427 ms |
| | Android emulator | 97–112 ms | **40–48 ms** | 44–54 ms | 625–674 ms |
| | iOS simulator | 61–102 ms | **39–51 ms** | 45–65 ms | 378–425 ms² |
| → 512px thumbnail | macOS | **15–25 ms** | | 11–20 ms¹ | 178–203 ms |
| | Android emulator | **14–25 ms** | | 20–29 ms | |
| | iOS simulator | **14–25 ms** | | 21–37 ms | |
| Full-res re-encode | Android emulator | 133–256 ms | | **40–70 ms** | |
| | iOS simulator | 156–268 ms | | **87–115 ms** | |
| 12 photos at once → 1920px | Android emulator | 267 ms | | **193 ms** | |
| | iOS simulator | 210 ms | | **154 ms** | |

¹ Apple ImageIO directly (`benchmark/imageio.swift`), the best case of what fic does on iOS.
² Debug build (simulators only run debug), so Dart is JIT — treat as indicative. Native code
(rimg, fic) runs fully optimised; the hook always builds Rust in release.

Emulator/simulator run on the M5 host CPU, not phone CPUs — compare ratios, not absolute times.

### Size at equal visual quality (full resolution, colour-managed SSIMULACRA2)

KB needed to reach a score of 70 / 80 / 85 (higher score = closer to the original; 80 ≈ high quality).

| Encoder | photo | horizon |
|---|---|---|
| **rimg balanced (mozjpeg)** | **123 / 207 / 317** | **783 / 1222 / 1666** |
| rimg fast | 139 / 249 / 557 | 910 / 1321 / 1959 |
| rimg WebP | – / 198 / – | 947 / 1458 / – |
| fic on Android (libjpeg-turbo) | 139 / 249 / 557 | 910 / 1320 / 1957 |
| Apple ImageIO | – / 330 / 558 | – / 1290 / 1840 |
| fic on iOS | – / 457 / – (caps at 84) | – / 1293 / 1903 |
| `image` (Dart) | 411 / 759 / – | 1210 / 1823 / – |

"–" = that score isn't reached within q40–q90. Note "q80" means very different
things per encoder (ImageIO/fic-iOS q80 is near-lossless and 3–5× larger than mozjpeg q80),
so always compare at equal score. Sanity check: rimg `fast` and fic-Android are identical,
as they should be (both libjpeg-turbo, both keep the P3 profile).

### HEIC input (12 MP Display P3 HEIC → JPEG)

| Task | Platform | rimg balanced | rimg `fast` | fic |
|---|---|---|---|---|
| → 1920px | iOS simulator | 75 ms / 68 KB | **56 ms** / 79 KB | 63 ms / 181 KB |
| | Android emulator | 113 ms / 72 KB | **94 ms** / 84 KB | 98 ms / 79 KB |
| | macOS (`compress()` in Rust) | 50 ms | | |
| → 512px | iOS simulator | **34 ms** | | 50 ms |
| | Android emulator | **62 ms** | | 65 ms |

Orientation (EXIF/irot 6) is applied correctly on both platforms; colour-managed mean of
the outputs matches the source within ~1 level on iOS and Android.

### Binary size (stripped, per ABI)

| Build | Android arm64 | iOS arm64 |
|---|---|---|
| **default (no AVIF)** | **3.9 MB** | **3.8 MB** |
| with `avif: true` | 6.4 MB | 6.2 MB |

## Takeaways

* **vs pure Dart**: 4–12× faster and 33–75% smaller files at equal quality. Clear win.
* **vs flutter_image_compress**:
  * `effort: fast` ≈ fic speed for resize-and-upload; `balanced` is ~2× slower per image.
  * Thumbnails: rimg is faster on both platforms (DCT-scaled decode).
  * Full-res re-encode and big batches: fic is faster (platform decoders + no trellis).
  * Files (photo, score 80–85): `balanced` is 17–43% smaller than fic-Android, 37–43% smaller
    than ImageIO and 55% smaller than fic-iOS. On the detailed image: 5–15% smaller.
  * Also: identical output on every platform, WebP/AVIF, exact target size, desktop support.
  * Cost: +3.9 MB per ABI (+6.4 MB with AVIF enabled).
* **Recommendation**: use rimg `balanced` where upload bytes matter (chat/media uploads,
  slow networks), `fast` where latency matters; keep fic if neither size nor formats matter.

## Fixed along the way

* **Colour bug** (found via the iOS run): rimg ignored ICC profiles, so Display P3 photos lost
  their colour space and looked shifted. Now JPEG embeds the source profile and other formats
  convert to sRGB via `qcms`; covered by a test.
* zune-jpeg sometimes drops valid ICC profiles; rimg parses JPEG `ICC_PROFILE` chunks itself.
* Xcode runs build hooks without `~/.cargo/bin` on PATH; `hook/build.dart` re-runs itself with it.
* Flutter 3.44 pins `meta 1.18`, so `native_toolchain_rust` is held at 1.0.4+0 (`hooks` 2.0.x).
* Intel iOS simulator builds need `nasm` for rav1e; the example app excludes x86_64 simulator.
* `native_toolchain_rust` loses Cargo dependency paths that contain spaces, so the hook
  never re-ran after Rust edits. `hook/build.dart` now declares the `rust/` sources itself.
* HEIC: ImageIO reports alpha for opaque photos (made everything RGBA, ~3× slower) and
  `ShouldCacheImmediately` decoded twice — both fixed.

## Known issue: project paths with spaces

Flutter writes its `dart_build.d` depfile without escaping spaces, so in a folder like
`…/Application Support/…` neither Flutter nor Gradle notices Rust source changes and keeps
shipping the old library (`dart test` is unaffected). Seen in this prototype's folder; keep
the project in a path without spaces, or run `flutter clean` after editing Rust code.

## Not done yet

* Video compression: planned in [docs/video-plan.md](docs/video-plan.md).

* Not run on a physical phone (iPhone signing was skipped; no Android phone attached).
* HEIC on Windows/Linux (would need libheif as an opt-in feature).
* AVIF output quality is unscored (no AVIF decoder linked).
* Target-size mode re-encodes up to ~7 times (≈400 ms worst case on detailed photos).
* WebP output doesn't embed ICC (converted to sRGB instead).
