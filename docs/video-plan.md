# Plan: video compression (`rimg_video`)

Status: **planned, not started** (written 2026-11-17).

## Goal

Compress phone videos (camera recordings, gallery picks) before upload: smaller
resolution and bitrate, same orientation and colours, audio kept. It should be fast,
reliable on real-world files (iPhone HDR, portrait, long videos) and easy to call from Flutter:

```dart
final job = RimgVideo.compress(
  inputPath: picked.path,
  outputPath: '${tmp.path}/out.mp4',
  maxSize: 1280,                 // longest edge; 0 = keep
  bitrate: 2500000,              // or targetBytes: 25 * 1024 * 1024
  codec: RimgVideoCodec.h264,    // h264 (plays everywhere) | hevc (smaller)
);
job.progress.listen((p) => print('${(p * 100).round()}%'));
final out = await job.result;    // path, width, height, duration, bytes
// job.cancel();
```

## Key decisions

1. **Use the phone's hardware encoder, not Rust or FFmpeg.**
   - Speed: dedicated encoder chips are many times faster than CPU encoding and use far less battery.
   - Licensing: H.264/HEVC are patent-licensed through the OS; x264/x265 are GPL.
   - Size: adds ~0 MB on iOS, a little on Android (Media3, to be measured).
   - `ffmpeg_kit` was retired in 2025, so bundling FFmpeg isn't a maintained option.
2. **A separate package in this repo: `rimg_video/`** (a Flutter plugin), next to `rimg`.
   - `rimg` stays a pure-Dart + Rust package that also works in Dart CLI and desktop,
     with no Kotlin/Swift and no Media3 dependency for apps that only need images.
   - Apps that need both add both. Shared docs, benchmarks and test data live in this repo.
3. **Platform engines**
   | Platform | Engine | Why |
   |---|---|---|
   | iOS 13+ | AVFoundation: `AVAssetReader` → `AVAssetWriter` (Swift) | Full control of bitrate, size, codec, HDR → SDR; hardware VideoToolbox underneath |
   | Android (minSdk 21+, Media3's minimum) | Jetpack Media3 **Transformer** (Kotlin) | Google-maintained; handles rotation, HDR tone-mapping, odd OEM files, audio passthrough. Raw `MediaCodec` is notoriously device-specific |
4. **Dart ↔ native via Pigeon** (typed, generated method channels) plus an `EventChannel` for progress.
   No FFI needed: the work is long-running and native-side anyway.

## Behaviour to get right (the "reliable" part)

| Case | Expected result |
|---|---|
| iPhone HDR (10-bit HEVC, HLG / Dolby Vision) | Converted to SDR (BT.709) with correct colours, not grey/washed out. Optional `keepHdr` later |
| Portrait / rotated videos | Correct orientation in every player (keep the rotation flag or apply it) |
| Audio | Passthrough (no re-encode) when the codec is AAC; otherwise AAC 128 kbps. Videos with no audio work |
| Already small enough | Skip re-encoding and return the input/copy (`skipIfSmaller: true` default) |
| Long videos (10+ min, 4K) | Streamed, constant memory; progress at least once a second; cancel stops within ~1 s and deletes the partial file |
| App goes to background | iOS: finishes if it can within background time, otherwise fails cleanly with a "retry" error. Android: continues (Transformer runs off the main thread); optional foreground service later |
| Variable frame rate, 60/120/240 fps slo-mo | Option `maxFps` (default 30). Slo-mo keeps its timing |
| Odd inputs (screen recordings, WhatsApp videos, MKV/WebM on Android, corrupt files) | Either a valid MP4 or a typed `RimgVideoException`; never a crash |
| Output | MP4 with `faststart` (moov first) so it starts playing while uploading |

## Phases

1. **Scaffold** (½ day)
   - Create the `rimg_video/` Flutter plugin (iOS + Android), the Pigeon API, the Dart `RimgVideo` class and the job/progress/cancel model.
   - Add a "Video" tab to `example_app` that picks a video, compresses it and shows the before/after size and time.
2. **Android: Media3 Transformer** (1–1½ days)
   - Settings: resize (`Presentation.createForShortSide/Height`), bitrate (`VideoEncoderSettings`), codec, HDR → SDR (`HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL`), audio passthrough.
   - Progress via `getProgress` polling; cancel.
   - Measure the APK size added.
3. **iOS: AVFoundation** (1½–2 days)
   - Reader/writer pipeline with VideoToolbox settings (`AVVideoAverageBitRateKey`, `AVVideoMaxKeyFrameIntervalKey`, profile level).
   - Scaling through `AVVideoScalingModeKey` or a `CIContext`/`VTPixelTransferSession` for HDR → SDR.
   - Preferred transform copied for orientation; audio passthrough via `AVAssetWriterInput` with nil settings.
   - Progress from presentation timestamps; cancel.
4. **Target-size mode** (½ day)
   - `targetBytes` → bitrate = (targetBytes × 8 / duration) − audio bitrate, with a safety margin and a floor.
   - Re-encode at most once more if the result overshoots by >10%.
5. **Tests & benchmark** (1–2 days)
   - Test video set in `testdata/video/`, short clips (5–15 s) to keep the repo small:
     iPhone HDR HEVC portrait, Android 1080p60 landscape, no-audio clip, screen recording, VFR clip, corrupt file.
   - Integration tests in `example_app` (`integration_test`) checking dimensions, orientation, duration ±0.1 s, audio present, colour (mean frame colour vs an SDR reference), cancel and errors.
   - Benchmark vs `video_compress` and `light_compressor`: time, output size and **VMAF** at equal size (ffmpeg with libvmaf on the Mac).
     Same rule as images: compare quality at equal size, not "same preset".
6. **Docs** (½ day): update the README and this file with results; decide whether it's good enough to use.

Rough total: **6–8 working days**, plus real-phone testing.

## Testing limits

- Simulator and emulator use software or host encoders, so **speed numbers from them are meaningless for video**.
  They are fine for correctness (orientation, colour, audio, cancel).
- Speed and battery need a **real Android phone and a real iPhone**. For the iPhone that means a signed build,
  which was skipped for the image work. Decide before phase 5:
  a personal team, or Xcode automatic signing on the user's own device.

## Open questions (decide before starting)

1. Default codec: **H.264** (plays everywhere, ~30–40% bigger) or **HEVC** (smaller; older Android/web players may fail)?
   Suggest H.264 default, HEVC opt-in.
2. Default quality preset, e.g. 720p @ 2.5 Mbps or 1080p @ 4–5 Mbps? Depends on the app (chat vs content).
3. Is HDR passthrough ever needed (e.g. for a video app), or always SDR?
4. Do we also want video **thumbnails** (first frame / at time t → JPEG via `rimg`)? Cheap to add in phase 1.
5. Minimum OS: iOS 13 / Android 5 (Media3) acceptable for the target apps?

## Risks

- **Android device fragmentation:** some OEM encoders reject certain sizes or bitrates.
  Media3 has fallbacks; we must test on at least one Samsung and one Pixel.
- **iOS HDR → SDR** with AVAssetWriter needs care: wrong colour properties produce washed-out output.
  `AVAssetExportSession` presets do it automatically but give no bitrate control. Fallback: export session presets for HDR input.
- **Background limits on iOS:** long encodes can be killed. Mitigate with a clear error and resume-by-retry, not partial files.
