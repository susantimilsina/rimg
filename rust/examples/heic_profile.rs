use std::time::Instant;
fn main() {
    let data = std::fs::read("../testdata/photo_12mp.heic").unwrap();
    for (w, h) in [(1920, 1920), (512, 512), (0, 0)] {
        let _ = rimg::heif::decode(&data, w, h).unwrap();
        let t = Instant::now();
        let mut d = None;
        for _ in 0..5 { d = Some(rimg::heif::decode(&data, w, h).unwrap()); }
        let d = d.unwrap();
        let o = rimg::RimgOptions { max_width: w, max_height: h, format: 0, quality: 80, target_bytes: 0, avif_speed: 0, effort: 0 };
        let _ = rimg::compress(&data, &o);
        let t2 = Instant::now();
        for _ in 0..5 { let _ = rimg::compress(&data, &o).unwrap(); }
        println!("  compress() end-to-end: {:.1} ms", t2.elapsed().as_secs_f64() * 200.0);
        println!("heif::decode box {w}x{h}: {:.1} ms -> {}x{} {:?} icc={}", t.elapsed().as_secs_f64() * 200.0, d.image.width(), d.image.height(), d.image.color(), d.icc.map(|i| i.len()).unwrap_or(0));
    }
}

#[allow(dead_code)]
fn _unused() {}
