//! rimg — fast image compression core for Flutter/Dart via a plain C ABI.
//!
//! Pipeline: decode (JPEG/PNG/WebP) -> apply EXIF orientation -> SIMD resize
//! -> encode (mozjpeg JPEG / libwebp WebP / AVIF / PNG), with an optional
//! "fit under N bytes" mode that searches quality, then downscales.

use std::ffi::{CString, c_char};
use std::io::Cursor;
use std::panic::{AssertUnwindSafe, catch_unwind};

use fast_image_resize::{FilterType, ResizeAlg, ResizeOptions, Resizer};
use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageReader};

pub mod heif;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum Format {
    Jpeg = 0,
    Webp = 1,
    Avif = 2,
    Png = 3,
}

impl Format {
    fn from_u32(v: u32) -> Result<Self, String> {
        Ok(match v {
            0 => Format::Jpeg,
            1 => Format::Webp,
            2 => Format::Avif,
            3 => Format::Png,
            _ => return Err(format!("unknown format {v}")),
        })
    }
}

/// Options passed from Dart. Zero means "not set" for every field.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct RimgOptions {
    /// Longest-edge style bounding box; aspect ratio is kept, never upscales.
    pub max_width: u32,
    pub max_height: u32,
    /// 0 = JPEG, 1 = WebP, 2 = AVIF, 3 = PNG
    pub format: u32,
    /// 1..=100 (ignored for PNG). 0 -> 80.
    pub quality: u32,
    /// If > 0, output is made <= this many bytes (quality search, then downscale).
    pub target_bytes: u64,
    /// AVIF speed 1 (slow, small) ..= 10 (fast). 0 -> 8.
    pub avif_speed: u32,
    /// JPEG encoder effort: 0 = balanced (mozjpeg trellis, default),
    /// 1 = fast (libjpeg-turbo-like, bigger files), 2 = max (search scans; slowest, smallest).
    pub effort: u32,
}

#[repr(C)]
pub struct RimgResult {
    /// Encoded bytes (free with `rimg_free`). Null on error.
    pub data: *mut u8,
    pub len: usize,
    pub width: u32,
    pub height: u32,
    /// Quality actually used (useful in target_bytes mode).
    pub quality: u32,
    /// Null on success, otherwise a NUL-terminated message (freed by `rimg_free`).
    pub error: *mut c_char,
}

pub struct Output {
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub quality: u32,
}

// ---------------------------------------------------------------- pipeline

pub fn decode(input: &[u8]) -> Result<DynamicImage, String> {
    if heif::is_heif(input) {
        return heif::decode(input, 0, 0).map(|d| d.image);
    }
    let reader = ImageReader::new(Cursor::new(input))
        .with_guessed_format()
        .map_err(|e| e.to_string())?;
    let mut decoder = reader.into_decoder().map_err(|e| e.to_string())?;
    let orientation = decoder.orientation().map_err(|e| e.to_string())?;
    let mut img = DynamicImage::from_decoder(decoder).map_err(|e| e.to_string())?;
    img.apply_orientation(orientation);
    Ok(img)
}

fn fit(w: u32, h: u32, max_w: u32, max_h: u32) -> (u32, u32) {
    let max_w = if max_w == 0 { w } else { max_w };
    let max_h = if max_h == 0 { h } else { max_h };
    if w <= max_w && h <= max_h {
        return (w, h);
    }
    let scale = f64::min(max_w as f64 / w as f64, max_h as f64 / h as f64);
    (
        ((w as f64 * scale).round() as u32).max(1),
        ((h as f64 * scale).round() as u32).max(1),
    )
}

pub fn resize(img: &DynamicImage, w: u32, h: u32) -> Result<DynamicImage, String> {
    if img.width() == w && img.height() == h {
        return Ok(img.clone());
    }
    let mut dst = DynamicImage::new(w, h, img.color());
    let opts = ResizeOptions::new().resize_alg(ResizeAlg::Convolution(FilterType::Lanczos3));
    Resizer::new()
        .resize(img, &mut dst, &opts)
        .map_err(|e| e.to_string())?;
    Ok(dst)
}

/// `icc`: profile to embed (JPEG only); pixels must already be in that space.
pub fn encode(img: &DynamicImage, format: Format, quality: u32, avif_speed: u32, effort: u32, icc: Option<&[u8]>) -> Result<Vec<u8>, String> {
    let q = quality.clamp(1, 100);
    let (w, h) = (img.width(), img.height());
    match format {
        Format::Jpeg => {
            let rgb = img.to_rgb8();
            // mozjpeg reports errors by unwinding; contain it here.
            catch_unwind(|| -> std::io::Result<Vec<u8>> {
                let mut c = mozjpeg::Compress::new(mozjpeg::ColorSpace::JCS_RGB);
                if effort == 1 {
                    c.set_fastest_defaults();
                    c.set_optimize_coding(true);
                }
                c.set_size(w as usize, h as usize);
                c.set_quality(q as f32);
                if effort != 1 {
                    c.set_progressive_mode();
                    c.set_optimize_scans(effort >= 2);
                }
                let mut c = c.start_compress(Vec::with_capacity((w * h / 4) as usize))?;
                if let Some(p) = icc {
                    c.write_icc_profile(p);
                }
                c.write_scanlines(rgb.as_raw())?;
                c.finish()
            })
            .map_err(|_| "mozjpeg panicked".to_string())?
            .map_err(|e| e.to_string())
        }
        Format::Webp => {
            let mem = if img.color().has_alpha() {
                let rgba = img.to_rgba8();
                webp::Encoder::from_rgba(rgba.as_raw(), w, h).encode(q as f32)
            } else {
                let rgb = img.to_rgb8();
                webp::Encoder::from_rgb(rgb.as_raw(), w, h).encode(q as f32)
            };
            Ok(mem.to_vec())
        }
        #[cfg(not(feature = "avif"))]
        Format::Avif => Err("built without AVIF support".into()),
        #[cfg(feature = "avif")]
        Format::Avif => {
            use rgb::FromSlice;
            let speed = if avif_speed == 0 { 8 } else { avif_speed.clamp(1, 10) } as u8;
            let enc = ravif::Encoder::new().with_quality(q as f32).with_speed(speed);
            let res = if img.color().has_alpha() {
                let rgba = img.to_rgba8();
                enc.encode_rgba(imgref::Img::new(rgba.as_raw().as_rgba(), w as usize, h as usize))
            } else {
                let rgb = img.to_rgb8();
                enc.encode_rgb(imgref::Img::new(rgb.as_raw().as_rgb(), w as usize, h as usize))
            };
            res.map(|r| r.avif_file).map_err(|e| e.to_string())
        }
        Format::Png => {
            use image::codecs::png::{CompressionType, FilterType as PngFilter, PngEncoder};
            let mut out = Vec::new();
            let enc = PngEncoder::new_with_quality(&mut out, CompressionType::Default, PngFilter::Adaptive);
            img.write_with_encoder(enc).map_err(|e| e.to_string())?;
            Ok(out)
        }
    }
}

fn swaps_axes(o: Orientation) -> bool {
    matches!(o, Orientation::Rotate90 | Orientation::Rotate270 | Orientation::Rotate90FlipH | Orientation::Rotate270FlipH)
}

/// Decoded source (NOT yet oriented, possibly DCT-downscaled), its EXIF
/// orientation, and the target size in the source's stored orientation.
struct Loaded {
    src: DynamicImage,
    orientation: Orientation,
    target: (u32, u32),
    /// Embedded-ICC -> sRGB transform (e.g. iPhone photos are Display P3).
    cms: Option<qcms::Transform>,
    icc: Option<Vec<u8>>,
    alpha: bool,
}

/// Transform from an embedded ICC profile to sRGB. None when there is no
/// profile or it can't be parsed (pixels are then treated as sRGB already).
fn srgb_transform(icc: Option<&[u8]>, alpha: bool) -> Option<qcms::Transform> {
    let src = qcms::Profile::new_from_slice(icc?, false)?;
    let ty = if alpha { qcms::DataType::RGBA8 } else { qcms::DataType::RGB8 };
    qcms::Transform::new(&src, &qcms::Profile::new_sRGB(), ty, qcms::Intent::Perceptual)
}

/// Reassembles an ICC profile from JPEG APP2 "ICC_PROFILE" chunks.
fn jpeg_icc(data: &[u8]) -> Option<Vec<u8>> {
    let mut chunks: Vec<(u8, &[u8])> = Vec::new();
    let mut i = 2; // after SOI
    while i + 4 <= data.len() && data[i] == 0xFF {
        let marker = data[i + 1];
        if marker == 0xDA || marker == 0xD9 {
            break; // start of scan / end of image
        }
        let len = u16::from_be_bytes([data[i + 2], data[i + 3]]) as usize;
        let seg = data.get(i + 4..i + 2 + len)?;
        if marker == 0xE2 && seg.len() > 14 && &seg[..12] == b"ICC_PROFILE\0" {
            chunks.push((seg[12], &seg[14..]));
        }
        i += 2 + len;
    }
    if chunks.is_empty() {
        return None;
    }
    chunks.sort_by_key(|c| c.0);
    Some(chunks.into_iter().flat_map(|c| c.1.iter().copied()).collect())
}

/// Converts to 8-bit RGB(A) and, if there is a transform, into sRGB.
fn to_srgb(img: DynamicImage, cms: Option<&qcms::Transform>, alpha: bool) -> DynamicImage {
    let Some(t) = cms else { return img };
    if alpha {
        let mut buf = img.into_rgba8();
        t.apply(&mut buf);
        DynamicImage::ImageRgba8(buf)
    } else {
        let mut buf = img.into_rgb8();
        t.apply(&mut buf);
        DynamicImage::ImageRgb8(buf)
    }
}

/// Full-resolution decode, EXIF-rotated and colour-managed to sRGB.
pub fn decode_srgb(input: &[u8]) -> Result<DynamicImage, String> {
    let l = load(input, 0, 0)?;
    let mut img = to_srgb(l.src, l.cms.as_ref(), l.alpha);
    img.apply_orientation(l.orientation);
    Ok(img)
}

fn load(input: &[u8], max_w: u32, max_h: u32) -> Result<Loaded, String> {
    // HEIC: the OS decodes it, already oriented and scaled near the target.
    if heif::is_heif(input) {
        let d = heif::decode(input, max_w, max_h)?;
        let alpha = d.image.color().has_alpha();
        let target = fit(d.image.width(), d.image.height(), max_w, max_h);
        let cms = srgb_transform(d.icc.as_deref(), alpha);
        return Ok(Loaded { src: d.image, orientation: Orientation::NoTransforms, target, cms, icc: d.icc, alpha });
    }
    let reader = ImageReader::new(Cursor::new(input))
        .with_guessed_format()
        .map_err(|e| e.to_string())?;
    let is_jpeg = reader.format() == Some(image::ImageFormat::Jpeg);
    let mut decoder = reader.into_decoder().map_err(|e| e.to_string())?;
    let orientation = decoder.orientation().map_err(|e| e.to_string())?;
    // Read JPEG ICC ourselves: zune-jpeg sometimes drops valid profiles.
    let icc = if is_jpeg { jpeg_icc(input) } else { decoder.icc_profile().ok().flatten() };
    let (w, h) = decoder.dimensions();
    let (mw, mh) = if swaps_axes(orientation) { (max_h, max_w) } else { (max_w, max_h) };
    let target = fit(w, h, mw, mh);

    // JPEG fast path: let libjpeg do part of the downscale inside the IDCT
    // (n/8 scaling), so we never materialise all 12 MP when we only need 2.
    if is_jpeg && target.0 < w {
        let n = (1..=8u32)
            .find(|n| (w * n).div_ceil(8) >= target.0 && (h * n).div_ceil(8) >= target.1)
            .unwrap_or(8);
        if n < 8 {
            if let Ok(src) = decode_jpeg_scaled(input, n as u8) {
                let cms = srgb_transform(icc.as_deref(), false);
                return Ok(Loaded { src, orientation, target, cms, icc, alpha: false });
            }
        }
    }
    let alpha = decoder.color_type().has_alpha();
    let src = DynamicImage::from_decoder(decoder).map_err(|e| e.to_string())?;
    let cms = srgb_transform(icc.as_deref(), alpha);
    Ok(Loaded { src, orientation, target, cms, icc, alpha })
}

fn decode_jpeg_scaled(input: &[u8], numerator: u8) -> Result<DynamicImage, String> {
    catch_unwind(|| -> std::io::Result<DynamicImage> {
        let mut d = mozjpeg::Decompress::new_mem(input)?;
        d.scale(numerator);
        let mut started = d.rgb()?;
        let (w, h) = (started.width() as u32, started.height() as u32);
        let px: Vec<u8> = started.read_scanlines()?;
        started.finish()?;
        image::RgbImage::from_raw(w, h, px)
            .map(DynamicImage::ImageRgb8)
            .ok_or_else(|| std::io::Error::other("bad buffer"))
    })
    .map_err(|_| "mozjpeg decode panicked".to_string())?
    .map_err(|e| e.to_string())
}

/// `to_srgb`: convert colours to sRGB (otherwise keep the source colour space,
/// and the caller embeds the source ICC profile).
fn resize_oriented(l: &Loaded, w: u32, h: u32, to_srgb_space: bool) -> Result<DynamicImage, String> {
    // Colour-convert and rotate the small image, not the big one.
    let img = resize(&l.src, w, h)?;
    let mut img = if to_srgb_space { to_srgb(img, l.cms.as_ref(), l.alpha) } else { img };
    img.apply_orientation(l.orientation);
    Ok(img)
}

pub fn compress(input: &[u8], o: &RimgOptions) -> Result<Output, String> {
    let format = Format::from_u32(o.format)?;
    let quality = if o.quality == 0 { 80 } else { o.quality.clamp(1, 100) };
    let loaded = load(input, o.max_width, o.max_height)?;
    let (mut w, mut h) = loaded.target;
    // JPEG keeps wide-gamut colours (e.g. iPhone Display P3) by embedding the
    // source profile, like ImageIO/Android do. Other formats convert to sRGB.
    let keep_icc = format == Format::Jpeg && loaded.cms.is_some();
    let icc = if keep_icc { loaded.icc.as_deref() } else { None };
    let mut img = resize_oriented(&loaded, w, h, !keep_icc)?;
    let enc = |img: &DynamicImage, q: u32| encode(img, format, q, o.avif_speed, o.effort, icc);

    let bytes = enc(&img, quality)?;
    if o.target_bytes == 0 || bytes.len() as u64 <= o.target_bytes || format == Format::Png {
        return Ok(Output { bytes, width: img.width(), height: img.height(), quality });
    }

    // Target-size mode: binary search quality in [MIN_Q, quality); if even
    // MIN_Q is too big, shrink dimensions by 15% and try again.
    const MIN_Q: u32 = 25;
    for _ in 0..8 {
        let (mut lo, mut hi) = (MIN_Q, quality - 1);
        let mut best: Option<(Vec<u8>, u32)> = None;
        while lo <= hi {
            let mid = (lo + hi) / 2;
            let b = enc(&img, mid)?;
            if b.len() as u64 <= o.target_bytes {
                best = Some((b, mid));
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        if let Some((bytes, q)) = best {
            return Ok(Output { bytes, width: img.width(), height: img.height(), quality: q });
        }
        w = ((w as f64) * 0.85) as u32;
        h = ((h as f64) * 0.85) as u32;
        if w < 16 || h < 16 {
            break;
        }
        img = resize_oriented(&loaded, w, h, !keep_icc)?;
    }
    Err(format!("could not fit under {} bytes", o.target_bytes))
}

// ---------------------------------------------------------------- C ABI

fn err_result(msg: String) -> RimgResult {
    RimgResult {
        data: std::ptr::null_mut(),
        len: 0,
        width: 0,
        height: 0,
        quality: 0,
        error: CString::new(msg).unwrap_or_default().into_raw(),
    }
}

/// Compress `input[..len]`. Always returns a result that must be passed to
/// `rimg_free`. Thread-safe: call it from any Dart isolate concurrently.
///
/// # Safety
/// `input` must point to `len` readable bytes; `opts` must be a valid pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rimg_compress(input: *const u8, len: usize, opts: *const RimgOptions) -> RimgResult {
    if input.is_null() || opts.is_null() {
        return err_result("null argument".into());
    }
    let (data, o) = unsafe { (std::slice::from_raw_parts(input, len), *opts) };
    match catch_unwind(AssertUnwindSafe(|| compress(data, &o))) {
        Ok(Ok(out)) => {
            let mut b = out.bytes.into_boxed_slice();
            let res = RimgResult {
                data: b.as_mut_ptr(),
                len: b.len(),
                width: out.width,
                height: out.height,
                quality: out.quality,
                error: std::ptr::null_mut(),
            };
            std::mem::forget(b);
            res
        }
        Ok(Err(e)) => err_result(e),
        Err(_) => err_result("internal panic".into()),
    }
}

/// Whether HEIC input can be decoded on this device (Apple: always;
/// Android: 11+; other platforms: no).
#[unsafe(no_mangle)]
pub extern "C" fn rimg_heic_supported() -> bool {
    heif::supported()
}

/// Whether this build includes the AVIF encoder (cargo feature `avif`).
#[unsafe(no_mangle)]
pub extern "C" fn rimg_avif_supported() -> bool {
    cfg!(feature = "avif")
}

/// Free buffers owned by a `RimgResult`.
///
/// # Safety
/// `r` must come from `rimg_compress` and be freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rimg_free(r: RimgResult) {
    if !r.data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(r.data, r.len)) });
    }
    if !r.error.is_null() {
        drop(unsafe { CString::from_raw(r.error) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fit_keeps_aspect_and_never_upscales() {
        assert_eq!(fit(4032, 3024, 1920, 1920), (1920, 1440));
        assert_eq!(fit(3024, 4032, 1920, 1920), (1440, 1920));
        assert_eq!(fit(800, 600, 1920, 1920), (800, 600));
        assert_eq!(fit(800, 600, 0, 0), (800, 600));
    }

    #[test]
    fn roundtrip_all_formats_and_target() {
        let img = DynamicImage::ImageRgb8(image::RgbImage::from_fn(640, 480, |x, y| {
            image::Rgb([(x % 256) as u8, (y % 256) as u8, ((x * y) % 256) as u8])
        }));
        let mut png = Vec::new();
        img.write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        for f in 0..4 {
            let o = RimgOptions { max_width: 320, max_height: 320, format: f, quality: 75, target_bytes: 0, avif_speed: 10, effort: 0 };
            if f == 2 && !rimg_avif_supported() {
                assert!(compress(&png, &o).is_err(), "AVIF must error when built without it");
                continue;
            }
            let out = compress(&png, &o).unwrap();
            assert_eq!((out.width, out.height), (320, 240));
            assert!(!out.bytes.is_empty());
        }
        let o = RimgOptions { max_width: 0, max_height: 0, format: 0, quality: 95, target_bytes: 20_000, avif_speed: 0, effort: 0 };
        let out = compress(&png, &o).unwrap();
        assert!(out.bytes.len() <= 20_000, "{}", out.bytes.len());
        // decodes back
        decode(&out.bytes).unwrap();
    }

    fn testdata(name: &str) -> Vec<u8> {
        std::fs::read(format!("{}/../testdata/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
    }

    fn mean_srgb(bytes: &[u8]) -> Vec<f64> {
        let img = decode_srgb(bytes).unwrap().to_rgb8();
        let n = (img.width() * img.height()) as f64;
        (0..3).map(|c| img.pixels().map(|p| p[c] as f64).sum::<f64>() / n).collect()
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn heic_input() {
        assert!(rimg_heic_supported());
        let heic = testdata("photo_12mp.heic");
        assert!(heif::is_heif(&heic));
        let o = RimgOptions { max_width: 1920, max_height: 1920, format: 0, quality: 80, target_bytes: 0, avif_speed: 0, effort: 0 };
        // Same colours as the JPEG source (P3 kept + embedded for JPEG, converted for WebP).
        let want = mean_srgb(&testdata("photo_12mp.jpg"));
        for format in [Format::Jpeg as u32, Format::Webp as u32] {
            let out = compress(&heic, &RimgOptions { format, ..o }).unwrap();
            assert_eq!((out.width, out.height), (1920, 1440));
            let got = mean_srgb(&out.bytes);
            for (g, w) in got.iter().zip(&want) {
                assert!((g - w).abs() < 2.0, "format {format}: {got:?} vs {want:?}");
            }
        }
        // Full size (no box) keeps 4032x3024.
        let full = compress(&heic, &RimgOptions { max_width: 0, max_height: 0, ..o }).unwrap();
        assert_eq!((full.width, full.height), (4032, 3024));
        // Target-size mode works on HEIC too.
        let small = compress(&heic, &RimgOptions { quality: 95, target_bytes: 100_000, ..o }).unwrap();
        assert!(small.bytes.len() <= 100_000);
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn heic_orientation_applied() {
        // 400x300 stored, orientation 6 -> displayed 300x400.
        let o = RimgOptions { max_width: 0, max_height: 0, format: 0, quality: 80, target_bytes: 0, avif_speed: 0, effort: 0 };
        let out = compress(&testdata("rotated.heic"), &o).unwrap();
        assert_eq!((out.width, out.height), (300, 400));
        let boxed = compress(&testdata("rotated.heic"), &RimgOptions { max_width: 200, max_height: 200, ..o }).unwrap();
        assert_eq!((boxed.width, boxed.height), (150, 200));
    }

    #[test]
    fn our_outputs_are_not_sniffed_as_heic() {
        let src = testdata("photo_12mp.jpg");
        let o = RimgOptions { max_width: 256, max_height: 256, format: 0, quality: 80, target_bytes: 0, avif_speed: 10, effort: 0 };
        for format in 0..4 {
            if format == 2 && !rimg_avif_supported() {
                continue;
            }
            let out = compress(&src, &RimgOptions { format, ..o }).unwrap();
            assert!(!heif::is_heif(&out.bytes), "format {format}");
        }
    }

    #[test]
    fn corrupt_heic_is_an_error_not_a_crash() {
        let mut heic = testdata("rotated.heic");
        heic.truncate(200);
        let o = RimgOptions { max_width: 0, max_height: 0, format: 0, quality: 80, target_bytes: 0, avif_speed: 0, effort: 0 };
        assert!(compress(&heic, &o).is_err());
    }

    #[test]
    fn display_p3_is_converted_to_srgb() {
        // Display P3 test photo; ImageIO's colour-managed sRGB mean is ~(133.3, 145.7, 111.8).
        let src = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../testdata/photo_12mp.jpg")).unwrap();
        let o = RimgOptions { max_width: 512, max_height: 512, format: 0, quality: 90, target_bytes: 0, avif_speed: 0, effort: 0 };
        for format in [Format::Jpeg as u32, Format::Webp as u32] {
            let o = RimgOptions { format, ..o };
            // JPEG embeds P3; WebP is converted. Either way, colour-managed
            // decoding must give the same sRGB colours as the source.
            let out = decode_srgb(&compress(&src, &o).unwrap().bytes).unwrap().to_rgb8();
            let n = (out.width() * out.height()) as f64;
            let mean: Vec<f64> = (0..3).map(|c| out.pixels().map(|p| p[c] as f64).sum::<f64>() / n).collect();
            for (got, want) in mean.iter().zip([133.3, 145.7, 111.8]) {
                assert!((got - want).abs() < 2.0, "format {format}: mean {mean:?}");
            }
        }
    }
}
