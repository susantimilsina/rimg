//! HEIC decoding on iOS/macOS through ImageIO + CoreGraphics (plain C APIs).

use std::ffi::c_void;
use std::ptr::null;

use image::{DynamicImage, RgbImage, RgbaImage};

use super::{Decoded, fit};

type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type CFDictionaryRef = *const c_void;
type CFDataRef = *const c_void;
type CFNumberRef = *const c_void;
type CFAllocatorRef = *const c_void;
type CGImageSourceRef = *const c_void;
type CGImageRef = *const c_void;
type CGColorSpaceRef = *const c_void;
type CGContextRef = *const c_void;

#[repr(C)]
struct CGRect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

#[repr(C)]
struct CFDictionaryKeyCallBacks([usize; 6]);
#[repr(C)]
struct CFDictionaryValueCallBacks([usize; 5]);

const K_CF_NUMBER_SINT64: isize = 4;
const K_CG_COLOR_SPACE_MODEL_RGB: i32 = 1;
const K_CG_IMAGE_ALPHA_PREMULTIPLIED_LAST: u32 = 1;
const K_CG_IMAGE_ALPHA_NONE_SKIP_LAST: u32 = 5;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFAllocatorNull: CFAllocatorRef;
    static kCFBooleanTrue: CFTypeRef;
    static kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
    static kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
    fn CFRelease(cf: CFTypeRef);
    fn CFDataCreateWithBytesNoCopy(a: CFAllocatorRef, bytes: *const u8, len: isize, dealloc: CFAllocatorRef) -> CFDataRef;
    fn CFDataGetLength(d: CFDataRef) -> isize;
    fn CFDataGetBytePtr(d: CFDataRef) -> *const u8;
    fn CFNumberCreate(a: CFAllocatorRef, ty: isize, value: *const c_void) -> CFNumberRef;
    fn CFNumberGetValue(n: CFNumberRef, ty: isize, value: *mut c_void) -> bool;
    fn CFDictionaryCreate(
        a: CFAllocatorRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        n: isize,
        kcb: *const CFDictionaryKeyCallBacks,
        vcb: *const CFDictionaryValueCallBacks,
    ) -> CFDictionaryRef;
    fn CFDictionaryGetValue(d: CFDictionaryRef, key: CFTypeRef) -> CFTypeRef;
}

#[link(name = "ImageIO", kind = "framework")]
unsafe extern "C" {
    static kCGImagePropertyPixelWidth: CFStringRef;
    static kCGImagePropertyPixelHeight: CFStringRef;
    static kCGImagePropertyOrientation: CFStringRef;
    static kCGImageSourceCreateThumbnailFromImageAlways: CFStringRef;
    static kCGImageSourceCreateThumbnailWithTransform: CFStringRef;
    static kCGImageSourceThumbnailMaxPixelSize: CFStringRef;
    fn CGImageSourceCreateWithData(data: CFDataRef, options: CFDictionaryRef) -> CGImageSourceRef;
    fn CGImageSourceCopyPropertiesAtIndex(s: CGImageSourceRef, i: usize, o: CFDictionaryRef) -> CFDictionaryRef;
    fn CGImageSourceCreateThumbnailAtIndex(s: CGImageSourceRef, i: usize, o: CFDictionaryRef) -> CGImageRef;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    static kCGColorSpaceSRGB: CFStringRef;
    fn CGImageGetWidth(i: CGImageRef) -> usize;
    fn CGImageGetHeight(i: CGImageRef) -> usize;
    fn CGImageGetAlphaInfo(i: CGImageRef) -> u32;
    fn CGImageGetColorSpace(i: CGImageRef) -> CGColorSpaceRef; // not owned
    fn CGColorSpaceGetModel(cs: CGColorSpaceRef) -> i32;
    fn CGColorSpaceCopyICCData(cs: CGColorSpaceRef) -> CFDataRef;
    fn CGColorSpaceCreateWithName(name: CFStringRef) -> CGColorSpaceRef;
    fn CGBitmapContextCreate(
        data: *mut c_void,
        w: usize,
        h: usize,
        bits_per_component: usize,
        bytes_per_row: usize,
        cs: CGColorSpaceRef,
        bitmap_info: u32,
    ) -> CGContextRef;
    fn CGContextDrawImage(c: CGContextRef, rect: CGRect, image: CGImageRef);
}

/// Owns a CF object and releases it on drop.
struct Cf(CFTypeRef);
impl Cf {
    fn new(p: CFTypeRef, what: &str) -> Result<Self, String> {
        if p.is_null() { Err(format!("ImageIO: {what} failed")) } else { Ok(Cf(p)) }
    }
}
impl Drop for Cf {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

unsafe fn number(n: i64) -> Cf {
    Cf(unsafe { CFNumberCreate(null(), K_CF_NUMBER_SINT64, &n as *const i64 as *const c_void) })
}

unsafe fn dict(pairs: &[(CFStringRef, CFTypeRef)]) -> Cf {
    let keys: Vec<CFTypeRef> = pairs.iter().map(|p| p.0).collect();
    let vals: Vec<CFTypeRef> = pairs.iter().map(|p| p.1).collect();
    Cf(unsafe {
        CFDictionaryCreate(
            null(),
            keys.as_ptr(),
            vals.as_ptr(),
            pairs.len() as isize,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        )
    })
}

unsafe fn get_i64(d: CFDictionaryRef, key: CFStringRef) -> Option<i64> {
    let v = unsafe { CFDictionaryGetValue(d, key) };
    let mut out = 0i64;
    (!v.is_null() && unsafe { CFNumberGetValue(v, K_CF_NUMBER_SINT64, &mut out as *mut i64 as *mut c_void) }).then_some(out)
}

pub fn decode(data: &[u8], max_w: u32, max_h: u32) -> Result<Decoded, String> {
    unsafe {
        let cfdata = Cf::new(
            CFDataCreateWithBytesNoCopy(null(), data.as_ptr(), data.len() as isize, kCFAllocatorNull),
            "CFData",
        )?;
        let src = Cf::new(CGImageSourceCreateWithData(cfdata.0, null()), "open image")?;
        let props = Cf::new(CGImageSourceCopyPropertiesAtIndex(src.0, 0, null()), "read properties")?;
        let (w, h) = (
            get_i64(props.0, kCGImagePropertyPixelWidth).ok_or("ImageIO: no width")? as u32,
            get_i64(props.0, kCGImagePropertyPixelHeight).ok_or("ImageIO: no height")? as u32,
        );
        // Orientations 5..=8 swap width and height for display.
        let (ow, oh) = match get_i64(props.0, kCGImagePropertyOrientation) {
            Some(5..=8) => (h, w),
            _ => (w, h),
        };
        let (tw, th) = fit(ow, oh, max_w, max_h);
        // The thumbnail API sizes by longest edge; it decodes at reduced
        // resolution and applies orientation in one go.
        let max_px = number(tw.max(th) as i64);
        let opts = dict(&[
            (kCGImageSourceCreateThumbnailFromImageAlways, kCFBooleanTrue),
            (kCGImageSourceCreateThumbnailWithTransform, kCFBooleanTrue),
            (kCGImageSourceThumbnailMaxPixelSize, max_px.0),
        ]);
        let img = Cf::new(CGImageSourceCreateThumbnailAtIndex(src.0, 0, opts.0), "decode")?;
        let (iw, ih) = (CGImageGetWidth(img.0), CGImageGetHeight(img.0));
        // ImageIO often reports an alpha channel for opaque HEIC photos, so
        // draw with alpha when it might exist and check the pixels afterwards.
        let maybe_alpha = !matches!(CGImageGetAlphaInfo(img.0), 0 | 5 | 6); // None, NoneSkipLast, NoneSkipFirst

        // Render into RGBA8 in the image's own colour space (keeps Display P3),
        // falling back to sRGB for non-RGB or unsupported spaces.
        let own_cs = CGImageGetColorSpace(img.0);
        let info = if maybe_alpha { K_CG_IMAGE_ALPHA_PREMULTIPLIED_LAST } else { K_CG_IMAGE_ALPHA_NONE_SKIP_LAST };
        let mut buf = vec![0u8; iw * ih * 4];
        let srgb = Cf(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
        let mut cs = srgb.0;
        let mut ctx = std::ptr::null();
        if !own_cs.is_null() && CGColorSpaceGetModel(own_cs) == K_CG_COLOR_SPACE_MODEL_RGB {
            ctx = CGBitmapContextCreate(buf.as_mut_ptr() as *mut c_void, iw, ih, 8, iw * 4, own_cs, info);
            if !ctx.is_null() {
                cs = own_cs;
            }
        }
        if ctx.is_null() {
            ctx = CGBitmapContextCreate(buf.as_mut_ptr() as *mut c_void, iw, ih, 8, iw * 4, srgb.0, info);
        }
        let ctx = Cf::new(ctx, "bitmap context")?;
        CGContextDrawImage(ctx.0, CGRect { x: 0.0, y: 0.0, w: iw as f64, h: ih as f64 }, img.0);
        drop(ctx);

        let icc = if cs == srgb.0 {
            None
        } else {
            let d = CGColorSpaceCopyICCData(cs);
            if d.is_null() {
                None
            } else {
                let d = Cf(d);
                Some(std::slice::from_raw_parts(CFDataGetBytePtr(d.0), CFDataGetLength(d.0) as usize).to_vec())
            }
        };

        let (iw, ih) = (iw as u32, ih as u32);
        let alpha = maybe_alpha && buf.chunks_exact(4).any(|p| p[3] != 255);
        let image = if alpha {
            // Undo CoreGraphics' premultiplication.
            for px in buf.chunks_exact_mut(4) {
                let a = px[3] as u32;
                if a != 0 && a != 255 {
                    for c in &mut px[..3] {
                        *c = ((*c as u32 * 255 + a / 2) / a).min(255) as u8;
                    }
                }
            }
            DynamicImage::ImageRgba8(RgbaImage::from_raw(iw, ih, buf).ok_or("bad buffer")?)
        } else {
            let rgb: Vec<u8> = buf.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
            DynamicImage::ImageRgb8(RgbImage::from_raw(iw, ih, rgb).ok_or("bad buffer")?)
        };
        Ok(Decoded { image, icc })
    }
}
