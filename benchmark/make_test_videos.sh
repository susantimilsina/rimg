#!/usr/bin/env bash
# Generates the synthetic test videos in testdata/video/ (needs ffmpeg with libx264/libx265).
set -euo pipefail
cd "$(dirname "$0")/../testdata/video"
F=(ffmpeg -hide_banner -loglevel error -y)
X265="log-level=error"
# Real phone recordings are tagged BT.709; build the YUV with that matrix and tag it.
SDR="scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709"
NOTAG="scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown"
TAG=(-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv)

# Typical Android recording: landscape 1080p30 H.264 + AAC, high bitrate.
"${F[@]}" -f lavfi -i "testsrc2=size=1920x1080:rate=30,$SDR" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 8 -c:v libx264 -preset fast -b:v 16M -maxrate 16M -bufsize 32M "${TAG[@]}" -c:a aac -b:a 192k -movflags +faststart landscape_1080p30.mp4

# iPhone-style portrait: stored landscape, rotation flag 90, HEVC 60 fps.
"${F[@]}" -f lavfi -i "testsrc2=size=1920x1080:rate=60,$SDR" -f lavfi -i "sine=frequency=660:sample_rate=48000" \
  -t 6 -c:v libx265 -preset fast -b:v 12M -tag:v hvc1 -x265-params "$X265" "${TAG[@]}" -c:a aac -b:a 128k _portrait_tmp.mov
# Add the rotation flag without touching the pixels (ffmpeg's -display_rotation is counter-clockwise).
"${F[@]}" -display_rotation -90 -i _portrait_tmp.mov -c copy portrait_hevc_60fps.mov && rm _portrait_tmp.mov

# iPhone HDR: 10-bit HEVC, HLG transfer, BT.2020.
"${F[@]}" -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "sine=frequency=550:sample_rate=48000" \
  -t 5 -vf format=yuv420p10le -c:v libx265 -preset fast -b:v 10M -tag:v hvc1 \
  -x265-params "$X265:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -c:a aac -b:a 128k hdr_hlg_hevc.mov

# Screen-recording-like: 4K, no audio.
"${F[@]}" -f lavfi -i "testsrc2=size=3840x2160:rate=30,$SDR" -t 5 -c:v libx264 -preset ultrafast -b:v 30M "${TAG[@]}" no_audio_4k.mp4

# Already small: should be copied, not re-encoded.
"${F[@]}" -f lavfi -i "testsrc2=size=640x360:rate=30,$SDR" -f lavfi -i "sine=frequency=330:sample_rate=48000" \
  -t 5 -c:v libx264 -b:v 800k "${TAG[@]}" -c:a aac -b:a 96k already_small.mp4

# Corrupt: a chunk from the middle of a real file.
head -c 200000 landscape_1080p30.mp4 | tail -c 150000 > corrupt.mp4

# Untagged SD-ish clip (web downloads, some messengers): players must guess the colour space.
"${F[@]}" -f lavfi -i "testsrc2=size=1280x720:rate=30,$NOTAG" -f lavfi -i "sine=frequency=500:sample_rate=48000" \
  -t 4 -c:v libx264 -preset fast -b:v 6M -c:a aac -b:a 128k untagged_720p.mp4
