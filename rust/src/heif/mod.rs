//! HEIC/HEIF input via the operating system's decoder.
//!
//! HEIC is HEVC-coded, so instead of bundling a decoder (size, LGPL, patents)
//! we call the one the OS already ships: ImageIO on Apple platforms and the
//! NDK `AImageDecoder` on Android 11+. Both decode at reduced size, which is
//! much faster than decoding all 12 MP and resizing.

use image::DynamicImage;

#[cfg(target_vendor = "apple")]
mod apple;
#[cfg(target_os = "android")]
mod android;

/// A decoded HEIF image: already EXIF/irot-oriented, scaled to roughly the
/// requested box (never smaller), in the colour space described by `icc`
/// (None = sRGB).
pub struct Decoded {
    pub image: DynamicImage,
    pub icc: Option<Vec<u8>>,
}

const HEVC_BRANDS: [&[u8; 4]; 8] = [b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"hevm", b"hevs"];

/// True if `data` is an HEVC-coded HEIF file (HEIC). AVIF (also HEIF-based,
/// but AV1-coded) is deliberately not matched.
pub fn is_heif(data: &[u8]) -> bool {
    if data.len() < 16 || &data[4..8] != b"ftyp" {
        return false;
    }
    let size = (u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize).min(data.len());
    if size < 16 {
        return false;
    }
    // major brand at 8..12, minor version at 12..16, compatible brands after.
    std::iter::once(&data[8..12])
        .chain(data[16..size].chunks_exact(4))
        .any(|brand| HEVC_BRANDS.iter().any(|b| &b[..] == brand))
}

/// Whether HEIC decoding is available on this device.
pub fn supported() -> bool {
    #[cfg(target_vendor = "apple")]
    return true;
    #[cfg(target_os = "android")]
    return android::supported();
    #[cfg(not(any(target_vendor = "apple", target_os = "android")))]
    return false;
}

/// Decodes `data`, scaled so it still covers the `max_w` x `max_h` box
/// (in display orientation; 0 = unbounded).
#[allow(unused_variables)]
pub fn decode(data: &[u8], max_w: u32, max_h: u32) -> Result<Decoded, String> {
    #[cfg(target_vendor = "apple")]
    return apple::decode(data, max_w, max_h);
    #[cfg(target_os = "android")]
    return android::decode(data, max_w, max_h);
    #[cfg(not(any(target_vendor = "apple", target_os = "android")))]
    return Err("HEIC decoding is not supported on this platform".into());
}

/// Display P3 (D65 white, sRGB transfer curve) -> sRGB transform, built from
/// the standard primaries. Used where the OS reports "Display P3" without
/// giving us ICC bytes (Android's AImageDecoder). RGBA8 layout.
#[allow(dead_code)]
pub(crate) fn display_p3_to_srgb() -> Option<qcms::Transform> {
    use qcms::{CIE_xyY, CIE_xyYTRIPLE};
    let xy = |x, y| CIE_xyY { x, y, Y: 1.0 };
    let srgb_eotf: Vec<u16> = (0..1024)
        .map(|i| {
            let v = i as f64 / 1023.0;
            let lin = if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) };
            (lin * 65535.0).round() as u16
        })
        .collect();
    let primaries = CIE_xyYTRIPLE { red: xy(0.680, 0.320), green: xy(0.265, 0.690), blue: xy(0.150, 0.060) };
    let p3 = qcms::Profile::new_rgb_with_table(xy(0.3127, 0.3290), primaries, &srgb_eotf)?;
    qcms::Transform::new(&p3, &qcms::Profile::new_sRGB(), qcms::DataType::RGBA8, qcms::Intent::Perceptual)
}

/// Smallest size covering the box while keeping aspect ratio (same rule as
/// `crate::fit`, duplicated to keep this module self-contained).
pub(crate) fn fit(w: u32, h: u32, max_w: u32, max_h: u32) -> (u32, u32) {
    let max_w = if max_w == 0 { w } else { max_w };
    let max_h = if max_h == 0 { h } else { max_h };
    if w <= max_w && h <= max_h {
        return (w, h);
    }
    let s = f64::min(max_w as f64 / w as f64, max_h as f64 / h as f64);
    (((w as f64 * s).round() as u32).max(1), ((h as f64 * s).round() as u32).max(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ftyp(major: &[u8; 4], compat: &[&[u8; 4]]) -> Vec<u8> {
        let size = 16 + 4 * compat.len();
        let mut v = (size as u32).to_be_bytes().to_vec();
        v.extend_from_slice(b"ftyp");
        v.extend_from_slice(major);
        v.extend_from_slice(&[0; 4]);
        for c in compat {
            v.extend_from_slice(*c);
        }
        v.extend_from_slice(&[0; 16]);
        v
    }

    #[test]
    fn built_in_display_p3_matches_apple_profile() {
        // Raw P3 pixel values of the test photo (decoded without colour management),
        // converted with our primaries-based profile, must match the colour-managed
        // result using the photo's own (Apple) Display P3 ICC: ~(133.3, 145.7, 111.8).
        let jpg = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../testdata/photo_12mp.jpg")).unwrap();
        let mut px = crate::decode(&jpg).unwrap().resize(512, 384, image::imageops::FilterType::Triangle).to_rgba8();
        display_p3_to_srgb().unwrap().apply(&mut px);
        let n = (px.width() * px.height()) as f64;
        let mean: Vec<f64> = (0..3).map(|c| px.pixels().map(|p| p[c] as f64).sum::<f64>() / n).collect();
        for (got, want) in mean.iter().zip([133.3, 145.7, 111.8]) {
            assert!((got - want).abs() < 1.5, "{mean:?}");
        }
    }

    #[test]
    fn sniffing() {
        assert!(is_heif(&ftyp(b"heic", &[b"mif1", b"heic"])));
        assert!(is_heif(&ftyp(b"mif1", &[b"miaf", b"heic"]))); // iPhone-style
        assert!(!is_heif(&ftyp(b"avif", &[b"mif1", b"avif", b"miaf"])));
        assert!(!is_heif(&ftyp(b"mif1", &[b"miaf"])));
        assert!(!is_heif(b"\xFF\xD8\xFF\xE0 not a heif file at all"));
        assert!(!is_heif(&[]));
    }
}
