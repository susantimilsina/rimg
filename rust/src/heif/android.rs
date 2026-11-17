//! HEIC decoding on Android 11+ through the NDK `AImageDecoder` API.
//!
//! The symbols are resolved at runtime with `dlopen`, so apps with a lower
//! minSdk still load; on Android 9/10 `supported()` is simply false.

use std::ffi::{c_int, c_void};
use std::sync::OnceLock;

use image::{DynamicImage, RgbImage, RgbaImage};
use libloading::Library;

use super::{Decoded, display_p3_to_srgb, fit};

const SUCCESS: c_int = 0;
const ANDROID_BITMAP_FORMAT_RGBA_8888: i32 = 1;
const ANDROID_BITMAP_FLAGS_ALPHA_OPAQUE: c_int = 1;
const ADATASPACE_SRGB: i32 = 142_671_872;
const ADATASPACE_DISPLAY_P3: i32 = 143_261_696;

type Dec = c_void;
type Info = c_void;

struct Api {
    _lib: Library,
    create_from_buffer: unsafe extern "C" fn(*const c_void, usize, *mut *mut Dec) -> c_int,
    delete: unsafe extern "C" fn(*mut Dec),
    get_header_info: unsafe extern "C" fn(*const Dec) -> *const Info,
    info_width: unsafe extern "C" fn(*const Info) -> i32,
    info_height: unsafe extern "C" fn(*const Info) -> i32,
    info_alpha_flags: unsafe extern "C" fn(*const Info) -> c_int,
    info_data_space: unsafe extern "C" fn(*const Info) -> i32,
    set_format: unsafe extern "C" fn(*mut Dec, i32) -> c_int,
    set_unpremultiplied: unsafe extern "C" fn(*mut Dec, bool) -> c_int,
    set_data_space: unsafe extern "C" fn(*mut Dec, i32) -> c_int,
    compute_sampled_size: unsafe extern "C" fn(*const Dec, c_int, *mut i32, *mut i32) -> c_int,
    set_target_size: unsafe extern "C" fn(*mut Dec, i32, i32) -> c_int,
    min_stride: unsafe extern "C" fn(*mut Dec) -> usize,
    decode_image: unsafe extern "C" fn(*mut Dec, *mut c_void, usize, usize) -> c_int,
}

fn api() -> Option<&'static Api> {
    static API: OnceLock<Option<Api>> = OnceLock::new();
    API.get_or_init(|| unsafe {
        let lib = Library::new("libjnigraphics.so").ok()?;
        macro_rules! sym {
            ($name:literal) => {
                *lib.get($name).ok()?
            };
        }
        Some(Api {
            create_from_buffer: sym!(b"AImageDecoder_createFromBuffer\0"),
            delete: sym!(b"AImageDecoder_delete\0"),
            get_header_info: sym!(b"AImageDecoder_getHeaderInfo\0"),
            info_width: sym!(b"AImageDecoderHeaderInfo_getWidth\0"),
            info_height: sym!(b"AImageDecoderHeaderInfo_getHeight\0"),
            info_alpha_flags: sym!(b"AImageDecoderHeaderInfo_getAlphaFlags\0"),
            info_data_space: sym!(b"AImageDecoderHeaderInfo_getDataSpace\0"),
            set_format: sym!(b"AImageDecoder_setAndroidBitmapFormat\0"),
            set_unpremultiplied: sym!(b"AImageDecoder_setUnpremultipliedRequired\0"),
            set_data_space: sym!(b"AImageDecoder_setDataSpace\0"),
            compute_sampled_size: sym!(b"AImageDecoder_computeSampledSize\0"),
            set_target_size: sym!(b"AImageDecoder_setTargetSize\0"),
            min_stride: sym!(b"AImageDecoder_getMinimumStride\0"),
            decode_image: sym!(b"AImageDecoder_decodeImage\0"),
            _lib: lib,
        })
    })
    .as_ref()
}

pub fn supported() -> bool {
    api().is_some()
}

struct Guard<'a>(&'a Api, *mut Dec);
impl Drop for Guard<'_> {
    fn drop(&mut self) {
        unsafe { (self.0.delete)(self.1) }
    }
}

fn check(code: c_int, what: &str) -> Result<(), String> {
    if code == SUCCESS { Ok(()) } else { Err(format!("AImageDecoder: {what} failed ({code})")) }
}

pub fn decode(data: &[u8], max_w: u32, max_h: u32) -> Result<Decoded, String> {
    let api = api().ok_or("HEIC decoding requires Android 11 (API 30) or newer")?;
    unsafe {
        let mut dec = std::ptr::null_mut();
        check((api.create_from_buffer)(data.as_ptr() as *const c_void, data.len(), &mut dec), "open")?;
        let g = Guard(api, dec);
        let info = (api.get_header_info)(g.1);
        // AImageDecoder reports (and decodes in) display orientation.
        let (w, h) = ((api.info_width)(info) as u32, (api.info_height)(info) as u32);
        let alpha = (api.info_alpha_flags)(info) != ANDROID_BITMAP_FLAGS_ALPHA_OPAQUE;

        check((api.set_format)(g.1, ANDROID_BITMAP_FORMAT_RGBA_8888), "set RGBA_8888")?;
        if alpha {
            check((api.set_unpremultiplied)(g.1, true), "set unpremultiplied")?;
        }
        // AImageDecoder exposes no ICC bytes, only a dataspace. Output sRGB:
        // Display P3 (iPhone photos) is converted by us, because
        // setDataSpace(SRGB) was observed to be ignored for HEIF; for other
        // non-sRGB spaces ask the platform to convert (best effort).
        let data_space = (api.info_data_space)(info);
        let convert_p3 = data_space == ADATASPACE_DISPLAY_P3;
        if !convert_p3 && data_space != ADATASPACE_SRGB && data_space != 0 {
            let _ = (api.set_data_space)(g.1, ADATASPACE_SRGB);
        }

        // Decode at the largest power-of-two subsample that still covers the
        // target; our Lanczos resize does the final step for quality.
        let (tw, th) = fit(w, h, max_w, max_h);
        let (mut ow, mut oh) = (w, h);
        for sample in [8, 4, 2] {
            let (mut sw, mut sh) = (0i32, 0i32);
            if (api.compute_sampled_size)(g.1, sample, &mut sw, &mut sh) == SUCCESS
                && sw as u32 >= tw
                && sh as u32 >= th
            {
                check((api.set_target_size)(g.1, sw, sh), "set target size")?;
                (ow, oh) = (sw as u32, sh as u32);
                break;
            }
        }

        // Stride is computed for the current target size.
        let stride = (api.min_stride)(g.1);
        let mut buf = vec![0u8; stride * oh as usize];
        check((api.decode_image)(g.1, buf.as_mut_ptr() as *mut c_void, stride, buf.len()), "decode")?;

        let row_bytes = ow as usize * 4;
        let mut tight: Vec<u8> = if stride == row_bytes {
            buf
        } else {
            buf.chunks_exact(stride).flat_map(|r| r[..row_bytes].iter().copied()).collect()
        };
        if convert_p3 {
            display_p3_to_srgb().ok_or("could not build Display P3 transform")?.apply(&mut tight);
        }
        let image = if alpha {
            DynamicImage::ImageRgba8(RgbaImage::from_raw(ow, oh, tight).ok_or("bad buffer")?)
        } else {
            let rgb: Vec<u8> = tight.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
            DynamicImage::ImageRgb8(RgbImage::from_raw(ow, oh, rgb).ok_or("bad buffer")?)
        };
        Ok(Decoded { image, icc: None })
    }
}
