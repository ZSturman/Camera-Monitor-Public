#!/bin/sh
# Local RTSP fixture served by mediamtx, fed by ffmpeg test patterns:
#   rtsp://HOST:8554/fixture       H.264, no auth
#   rtsp://HOST:8554/fixture-h265  H.265, no auth
#   rtsp://fixture:fixture-pass@HOST:8554/secure  H.264, Basic/Digest auth
# HOST is 127.0.0.1 unless RTSP_FIXTURE_LISTEN is set (e.g. 0.0.0.0 to let a
# phone on the same LAN connect for device tests).
# Requires: brew install mediamtx ffmpeg
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$DIR/output"
mkdir -p "$OUT"
CONFIG="$OUT/mediamtx.yml"
LISTEN="${RTSP_FIXTURE_LISTEN:-127.0.0.1}"

cat > "$CONFIG" <<EOF
logLevel: warn
rtspAddress: $LISTEN:8554
rtspTransports: [tcp]
rtmp: no
hls: no
webrtc: no
srt: no
api: no
authInternalUsers:
  - user: any
    pass:
    ips: []
    permissions:
      - action: publish
      - action: read
        path: fixture
      - action: read
        path: fixture-h265
  - user: fixture
    pass: fixture-pass
    ips: []
    permissions:
      - action: read
        path: secure
paths:
  fixture:
  fixture-h265:
  secure:
    source: rtsp://127.0.0.1:8554/fixture
    sourceOnDemand: yes
EOF

# mediamtx writes auto.crt/auto.key into its working directory.
cd "$OUT"
mediamtx "$CONFIG" &
SERVER=$!
trap 'kill $SERVER $FEED $FEED265 2>/dev/null' EXIT INT TERM
sleep 1

ffmpeg -hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=1280x720:rate=10" \
    -c:v libx264 -preset veryfast -tune zerolatency -g 20 -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/fixture &
FEED=$!
ffmpeg -hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=1280x720:rate=10" \
    -c:v libx265 -preset ultrafast -tune zerolatency -x265-params "keyint=20:log-level=error" -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/fixture-h265 &
FEED265=$!
echo "RTSP fixture on $LISTEN:8554: /fixture (H.264), /fixture-h265 (H.265), fixture:fixture-pass@/secure"
wait $FEED
