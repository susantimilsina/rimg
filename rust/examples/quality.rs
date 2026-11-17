//! cargo run --release --example quality -- <original> <WxH> <candidate>...
//! Scores candidates with SSIMULACRA2 (higher = better; ~90 visually lossless,
//! ~70 high quality, ~50 medium) against the original resized to WxH.
use ssimulacra2::{ColorPrimaries, Rgb, TransferCharacteristic, compute_frame_ssimulacra2};

fn to_rgb(img: &image::DynamicImage) -> Rgb {
    let px: Vec<[f32; 3]> = img.to_rgb32f().pixels().map(|p| p.0).collect();
    Rgb::new(px, img.width() as usize, img.height() as usize, TransferCharacteristic::SRGB, ColorPrimaries::BT709).unwrap()
}

fn main() {
    let mut a = std::env::args().skip(1);
    let orig = rimg::decode_srgb(&std::fs::read(a.next().unwrap()).unwrap()).unwrap();
    let dims = a.next().unwrap();
    let (w, h) = dims.split_once('x').map(|(w, h)| (w.parse().unwrap(), h.parse().unwrap())).unwrap();
    let reference = to_rgb(&orig.resize_exact(w, h, image::imageops::FilterType::Lanczos3));
    for c in a {
        let bytes = std::fs::read(&c).unwrap();
        let img = rimg::decode_srgb(&bytes).unwrap();
        let s = compute_frame_ssimulacra2(reference.clone(), to_rgb(&img)).unwrap();
        println!("{:>7.1} KB  ssimulacra2 {:5.1}  {}", bytes.len() as f64 / 1024.0, s, c.rsplit('/').next().unwrap());
    }
}
