#!/usr/bin/env python3
"""Compares rimg_video outputs with their sources (needs ffmpeg/ffprobe).

    python3 benchmark/check_video_outputs.py <video_out dir> [reference.mp4 for HDR]

For every output "<stem>__<variant>.mp4" it finds testdata/video/<stem>.*, grabs
the frame at 2 s from both (colour-managed by ffmpeg, rotation applied, scaled to
64x36) and prints the mean absolute RGB difference. Untagged sources are read as
BT.709, which is what players assume for HD video. HDR sources can't be compared
directly with an SDR output, so pass Apple's own HDR->SDR export as the reference.
"""
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
W, H = 64, 36


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,color_space:stream_side_data=rotation", "-of", "json", path],
        capture_output=True, text=True, check=True).stdout
    s = json.loads(out)["streams"][0]
    rot = next((d.get("rotation", 0) for d in s.get("side_data_list", []) if "rotation" in d), 0)
    w, h = s["width"], s["height"]
    return (h, w) if rot % 180 else (w, h), s.get("color_space", "unknown")


def frame(path, untagged):
    vf = f"scale={W}:{H}" + (":in_color_matrix=bt709" if untagged else "") + ",format=rgb24"
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-ss", "2", "-i", path, "-frames:v", "1", "-vf", vf,
         "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    return raw


def diff(a, b):
    n = len(a) // 3
    return [round(sum(abs(a[i + c] - b[i + c]) for i in range(0, len(a), 3)) / n, 1) for c in range(3)]


def main():
    out_dir = sys.argv[1]
    hdr_ref = sys.argv[2] if len(sys.argv) > 2 else None
    print(f"{'output':44} {'size':>10}  {'vs source':>10}  mean |dRGB|")
    for out in sorted(glob.glob(os.path.join(out_dir, "*.mp4"))):
        name = os.path.basename(out)
        stem = name.split("__")[0]
        srcs = glob.glob(os.path.join(ROOT, "testdata", "video", stem + ".*"))
        if not srcs:
            continue
        src = srcs[0]
        (ow, oh), _ = probe(out)
        (sw, sh), src_space = probe(src)
        if "hdr" in stem:
            if not hdr_ref:
                print(f"{name:44} {ow}x{oh:<5}  (HDR: pass a reference export)")
                continue
            src, src_space = hdr_ref, "bt709"
        orient = "ok" if (ow > oh) == (sw > sh) else "WRONG"
        d = diff(frame(out, False), frame(src, src_space in ("unknown", "")))
        flag = "" if max(d) <= 4 else "  <-- colour differs"
        print(f"{name:44} {ow}x{oh:<5}  orient {orient:5}  {d}{flag}")


if __name__ == "__main__":
    main()
