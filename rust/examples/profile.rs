use rimg::*;
use std::time::Instant;
fn t<T: std::fmt::Debug>(label: &str, f: impl FnOnce() -> T) -> T {
    let s = Instant::now(); let r = f();
    println!("  {label:28} {:7.1} ms", s.elapsed().as_secs_f64() * 1e3); r
}
fn main() {
    for p in std::env::args().skip(1) {
        println!("{p}");
        let data = std::fs::read(&p).unwrap();
        let _ = decode(&data); // warm
        let img = t("decode (zune via image)", || decode(&data).unwrap());
        let small = t("resize -> 1920 lanczos3", || resize(&img, 1920, 1440).unwrap());
        let thumb = t("resize -> 512", || resize(&img, 512, 384).unwrap());
        t("encode jpeg 1920 q80 mozjpeg", || encode(&small, Format::Jpeg, 80, 0, 0, None).unwrap().len());
        t("encode jpeg 512 q75", || encode(&thumb, Format::Jpeg, 75, 0, 0, None).unwrap().len());
        t("encode webp 1920 q80", || encode(&small, Format::Webp, 80, 0, 0, None).unwrap().len());
        t("encode png 1920", || encode(&small, Format::Png, 0, 0, 0, None).unwrap().len());
        t("encode jpeg 1920 effort=fast", || encode(&small, Format::Jpeg, 80, 0, 1, None).unwrap().len());
        t("encode jpeg 1920 effort=max", || encode(&small, Format::Jpeg, 80, 0, 2, None).unwrap().len());
        let o = RimgOptions { max_width: 1920, max_height: 1920, format: 0, quality: 80, target_bytes: 0, avif_speed: 0, effort: 0 };
        let _ = compress(&data, &o);
        t("compress() end-to-end 1920", || compress(&data, &o).unwrap().bytes.len());
        t("encode jpeg full q80", || encode(&img, Format::Jpeg, 80, 0, 0, None).unwrap().len());
    }
}
