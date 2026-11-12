#!/usr/bin/env python3
"""Local fixture streams for developing and testing Camera Monitor without
real cameras or a Home Services server. Standard library only; requires
ffmpeg on PATH. Binds to 127.0.0.1 by default.

Endpoints (default http://127.0.0.1:8796):
  /hls/index.m3u8          live HLS (rolling 2 s segments, H.264 test pattern)
  /hls-auth/index.m3u8     same, behind HTTP Basic auth (fixture / fixture-pass)
  /mjpeg                   multipart/x-mixed-replace MJPEG test pattern
  /mjpeg-auth              same, behind HTTP Basic auth
  /mjpeg-stall             sends 3 frames, then holds the connection silent
  /mjpeg-flaky             repeating outage: up for 20 s, then 503 for 12 s
  /frigate/api/...         fake Frigate NVR (no auth, like port 5000)
  /frigate-auth/api/...    same, requiring POST api/login (fixture / fixture-pass)
  /go2rtc/api/...          fake go2rtc; its RTSP streams are rtsp.sh's paths
  /workspace/api/...       fake Workspace Sync camera dashboard (X-Workspace-Token: fixture-token)
  /onvif/device_service    fake ONVIF device (WS-Security fixture / fixture-pass)
  POST /_fixture/reset     restore the disposable recordings
  POST /_fixture/outage?seconds=N   streams fail and new requests get 503 for N s

These fakes follow each product's documented API; they don't certify any
real server. For Home Services, run its own development gateway (see
README). For RTSP, run Scripts/fixtures/rtsp.sh (needs mediamtx).
"""

import argparse
import base64
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "output"
BASIC_USER, BASIC_PASS = "fixture", "fixture-pass"
TOKEN = "fixture-token"
FRIGATE_JWT = "fixture-jwt"
PROCESSES = []


def ffmpeg(*args, **kwargs):
    return subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", *args], **kwargs)


def start_live_hls():
    target = OUT / "hls"
    shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True)
    PROCESSES.append(ffmpeg(
        "-re", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=10",
        "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-g", "20", "-pix_fmt", "yuv420p",
        "-f", "hls", "-hls_time", "2", "-hls_list_size", "6", "-hls_flags", "delete_segments+omit_endlist",
        str(target / "index.m3u8"),
    ))


def make_recordings():
    """A short VOD HLS for playback and an MP4 for export."""
    rec = OUT / "recording"
    if all((rec / n).exists() for n in ("index.m3u8", "export.mp4", "snapshot.jpg")):
        return
    rec.mkdir(parents=True, exist_ok=True)
    common = ["-y", "-f", "lavfi", "-i", "smptehdbars=size=1280x720:rate=10:duration=12",
              "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p"]
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", *common, "-f", "hls", "-hls_time", "4",
                    "-hls_playlist_type", "vod", str(rec / "index.m3u8")], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", *common, "-movflags", "+faststart",
                    str(rec / "export.mp4")], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360",
                    "-frames:v", "1", str(rec / "snapshot.jpg")], check=True)



class DisposableState:
    """Disposable recordings for destructive tests. Nothing here is real."""

    def __init__(self):
        now = time.time()
        self.lock = threading.Lock()
        self.armed = False
        self.outage_until = 0.0
        self.frigate_events = []
        labels = ["person", "car", "dog", "person", "package"]
        for i in range(12):
            start = now - 1800 - i * 3 * 3600
            self.frigate_events.append({
                "id": f"{start:.6f}-fx{i:02d}", "camera": "front_door", "label": labels[i % len(labels)],
                "sub_label": None, "start_time": start, "end_time": start + 20 + i,
                "has_clip": i % 4 != 3, "has_snapshot": True, "retain_indefinitely": i == 5,
            })
        self.frigate_events.insert(0, {"id": f"{now - 30:.6f}-active", "camera": "front_door", "label": "person",
                                       "sub_label": None, "start_time": now - 30, "end_time": None,
                                       "has_clip": True, "has_snapshot": True, "retain_indefinitely": False})
        self.workspace_events = [
            {"event_id": f"fixture-{i}", "start_ts": now - 3600 * (i + 1), "end_ts": now - 3600 * (i + 1) + 40,
             "last_motion_ts": now - 3600 * (i + 1) + 30, "camera_device_name": "Fixture Camera",
             "recording_started": True, "recording_path": "/fixture/recording.mp4", "synced": False, "notified": True}
            for i in range(3)
        ]

    def in_outage(self):
        return time.time() < self.outage_until


STATE = None

ONVIF_PROFILES = [("main", "MainStream", "H264", 1280, 720, "fixture"), ("sub", "SubStream", "H265", 1280, 720, "fixture-h265")]


def soap(body):
    return ('<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
            'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
            'xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body>' + body + '</s:Body></s:Envelope>').encode()


def wsse_ok(xml):
    import hashlib, re
    def field(name):
        m = re.search(r"<(?:\w+:)?" + name + r"(?:\s[^>]*)?>([^<]*)<", xml)
        return m.group(1) if m else None
    user, digest, nonce, created = field("Username"), field("Password"), field("Nonce"), field("Created")
    if not all([user, digest, nonce, created]) or user != BASIC_USER:
        return False
    expected = base64.b64encode(hashlib.sha1(base64.b64decode(nonce) + created.encode() + BASIC_PASS.encode()).digest()).decode()
    return expected == digest


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CameraMonitorFixture/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path.split("?")[0]))

    # -- helpers
    def send_bytes(self, status, body, content_type, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, status, obj):
        self.send_bytes(status, json.dumps(obj).encode(), "application/json")

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0") or 0))

    def query(self):
        from urllib.parse import parse_qs, urlparse
        return {k: v[0] for k, v in parse_qs(urlparse(self.path).query, keep_blank_values=True).items()}

    def basic_ok(self):
        expected = "Basic " + base64.b64encode(f"{BASIC_USER}:{BASIC_PASS}".encode()).decode()
        if self.headers.get("Authorization") == expected:
            return True
        self.send_bytes(401, b"", "text/plain", {"WWW-Authenticate": 'Basic realm="fixture"'})
        return False

    def host(self):
        return (self.headers.get("Host") or f"127.0.0.1:{self.server.server_port}").split(":")[0]

    def base_url(self):
        return f"http://{self.headers.get('Host') or f'127.0.0.1:{self.server.server_port}'}"

    def outage(self):
        if STATE.in_outage():
            self.send_bytes(503, b"fixture outage", "text/plain")
            return True
        return False

    # -- routing
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        global STATE
        path = self.path.split("?")[0]
        if path == "/_fixture/reset" and method == "POST":
            STATE = DisposableState()
            return self.send_bytes(204, b"", "text/plain")
        if path == "/_fixture/outage" and method == "POST":
            STATE.outage_until = time.time() + float(self.query().get("seconds", "10"))
            return self.send_bytes(204, b"", "text/plain")
        if path.startswith("/frigate-auth/"):
            return self.frigate(method, path[len("/frigate-auth"):], require_auth=True)
        if path.startswith("/frigate/"):
            return self.frigate(method, path[len("/frigate"):], require_auth=False)
        if path.startswith("/go2rtc/"):
            return self.go2rtc(path[len("/go2rtc"):])
        if path.startswith("/workspace/"):
            return self.workspace(method, path[len("/workspace"):])
        if path.startswith("/onvif/"):
            return self.onvif(path)
        if method != "GET":
            return self.send_bytes(404, b"", "text/plain")
        if path == "/snapshot.jpg":
            return self.static(OUT / "recording", "snapshot.jpg")
        if path.startswith("/hls-auth/"):
            if not self.basic_ok():
                return
            return self.static(OUT / "hls", path[len("/hls-auth/"):])
        if path.startswith("/hls/"):
            if self.outage():
                return
            return self.static(OUT / "hls", path[len("/hls/"):])
        if path.startswith("/recording/"):
            return self.static(OUT / "recording", path[len("/recording/"):])
        if path == "/mjpeg-auth":
            if not self.basic_ok():
                return
            return self.mjpeg()
        if path == "/mjpeg":
            return self.mjpeg()
        if path == "/mjpeg-stall":
            return self.mjpeg(stall_after=3)
        if path == "/mjpeg-flaky":
            return self.mjpeg(flaky=True)
        self.send_bytes(404, b"not found", "text/plain")

    def static(self, base, name):
        target = (base / name).resolve()
        if base.resolve() not in target.parents or not target.is_file():
            return self.send_bytes(404, b"not found", "text/plain")
        types = {".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t", ".mp4": "video/mp4", ".jpg": "image/jpeg"}
        data = target.read_bytes()
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes=") and target.suffix == ".mp4":
            first, _, last = rng[6:].partition("-")
            first = int(first or 0)
            last = int(last) if last else len(data) - 1
            chunk = data[first:last + 1]
            return self.send_bytes(206, chunk, "video/mp4", {"Content-Range": f"bytes {first}-{last}/{len(data)}", "Accept-Ranges": "bytes"})
        self.send_bytes(200, data, types.get(target.suffix, "application/octet-stream"), {"Accept-Ranges": "bytes"} if target.suffix == ".mp4" else None)

    @staticmethod
    def flaky_down():
        return time.time() % 32 >= 20

    def mjpeg(self, stall_after=None, flaky=False):
        if self.outage():
            return
        if flaky and self.flaky_down():
            return self.send_bytes(503, b"fixture outage", "text/plain")
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=ffmpeg")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        proc = ffmpeg("-re", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=8",
                      "-c:v", "mjpeg", "-q:v", "6", "-f", "mpjpeg", "-boundary_tag", "ffmpeg", "pipe:1",
                      stdout=subprocess.PIPE)
        sent_frames = 0
        try:
            while not STATE.in_outage() and not (flaky and self.flaky_down()):
                chunk = proc.stdout.read(16384)
                if not chunk:
                    break
                self.wfile.write(chunk)
                sent_frames += chunk.count(b"--ffmpeg")
                if stall_after and sent_frames > stall_after:
                    time.sleep(3600)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            proc.kill()
            self.close_connection = True

    # -- fake Frigate (documented HTTP API subset)
    def frigate(self, method, path, require_auth):
        if method == "POST" and path == "/api/login":
            creds = json.loads(self.body() or b"{}")
            if creds.get("user") == BASIC_USER and creds.get("password") == BASIC_PASS:
                return self.send_bytes(200, b"", "text/plain", {"Set-Cookie": f"frigate_token={FRIGATE_JWT}; Path=/; HttpOnly; SameSite=lax"})
            return self.send_json(401, {"message": "Login failed"})
        if require_auth and f"frigate_token={FRIGATE_JWT}" not in (self.headers.get("Cookie") or ""):
            return self.send_json(401, {"message": "Unauthorized"})
        q = self.query()
        if path == "/api/config":
            return self.send_json(200, {
                "cameras": {
                    "front_door": {"enabled": True, "record": {"enabled": True}, "snapshots": {"enabled": True},
                                   "detect": {"enabled": True, "width": 1280, "height": 720, "fps": 5}},
                    "back_yard": {"enabled": True, "record": {"enabled": False}, "snapshots": {"enabled": True},
                                  "detect": {"enabled": False, "width": 640, "height": 360, "fps": 5}},
                },
                "go2rtc": {"streams": {"front_door": ["rtsp://user:secret@camera.invalid/stream"]}},
            })
        if path == "/api/stats":
            return self.send_json(200, {"cameras": {"front_door": {"camera_fps": 10.0, "detection_fps": 1.2},
                                                    "back_yard": {"camera_fps": 0.0, "detection_fps": 0.0}},
                                        "service": {"version": "0.14.1-fixture"}})
        if path == "/api/events" and method == "GET":
            cams = set(filter(None, (q.get("cameras") or q.get("camera") or "").split(",")))
            before = float(q["before"]) if q.get("before") else None
            limit = int(q.get("limit", "50"))
            with STATE.lock:
                events = [e for e in STATE.frigate_events if (not cams or e["camera"] in cams) and (before is None or e["start_time"] < before)]
            return self.send_json(200, events[:limit])
        parts = [p for p in path.split("/") if p]
        if len(parts) >= 3 and parts[:2] == ["api", "events"]:
            with STATE.lock:
                event = next((e for e in STATE.frigate_events if e["id"] == parts[2]), None)
                if event is None:
                    return self.send_json(404, {"success": False, "message": "Event not found"})
                if parts[3:] == ["retain"] and method in ("POST", "DELETE"):
                    event["retain_indefinitely"] = method == "POST"
                    return self.send_json(200, {"success": True, "message": "Event retained" if method == "POST" else "Event un-retained"})
                if method == "DELETE" and len(parts) == 3:
                    if event["retain_indefinitely"]:
                        return self.send_json(400, {"success": False, "message": "Event is retained"})
                    STATE.frigate_events.remove(event)
                    return self.send_json(200, {"success": True, "message": f"Event {event['id']} deleted"})
            if parts[3:] == ["clip.mp4"] and event["has_clip"]:
                return self.static(OUT / "recording", "export.mp4")
            if parts[3:] in (["snapshot.jpg"], ["thumbnail.jpg"]):
                return self.static(OUT / "recording", "snapshot.jpg")
            return self.send_json(404, {"success": False, "message": "No media"})
        if len(parts) == 3 and parts[0] == "api" and parts[2] == "latest.jpg":
            return self.static(OUT / "recording", "snapshot.jpg")
        if len(parts) == 2 and parts[0] == "api" and parts[1] in ("front_door", "back_yard"):
            return self.mjpeg()
        return self.send_json(404, {"message": "Not found"})

    # -- fake go2rtc
    def go2rtc(self, path):
        q = self.query()
        if path == "/api":
            return self.send_json(200, {"version": "1.9.14-fixture", "rtsp": {"listen": ":8554"}})
        if path == "/api/streams":
            return self.send_json(200, {
                "fixture": {"producers": [{"url": "rtsp://user:secret@camera.invalid/main"}], "consumers": None},
                "fixture-h265": {"producers": [{"url": "ffmpeg:device?video=/dev/video0#video=h265"}], "consumers": None},
            })
        if path == "/api/frame.jpeg":
            return self.static(OUT / "recording", "snapshot.jpg")
        if path == "/api/stream.mjpeg":
            return self.mjpeg()
        if path == "/api/stream.m3u8":
            return self.send_bytes(302, b"", "text/plain", {"Location": "/hls/index.m3u8"})
        return self.send_json(404, {"error": "not found"})

    # -- fake Workspace Sync dashboard
    def workspace(self, method, path):
        if path == "/api/health":
            return self.send_json(200, {"status": "ok"})
        token = self.headers.get("X-Workspace-Token") or ""
        cookie = self.headers.get("Cookie") or ""
        if token != TOKEN and f"workspace_session={TOKEN}" not in cookie:
            return self.send_json(401, {"detail": "missing or invalid X-Workspace-Token"})
        if path == "/api/camera/status":
            live = {"enabled": True, "available": not STATE.in_outage(), "detail": "Live stream ready",
                    "width": 1280, "height": 720, "fps": 10, "playlist": "index.m3u8", "latest_segment_age_seconds": 1.2}
            return self.send_json(200, {"enabled": True, "available": True, "detail": "ready", "device": "/dev/video0",
                                        "width": 640, "height": 480, "refresh_seconds": 8, "out_of_house": STATE.armed,
                                        "recording": False, "current_event_id": None, "last_snapshot_at": time.time() - 60,
                                        "last_capture_error": None, "consecutive_failures": 0, "last_motion_at": None,
                                        "live_stream": live})
        if path.startswith("/api/camera/live/"):
            if self.outage():
                return
            return self.static(OUT / "hls", path[len("/api/camera/live/"):])
        if path in ("/api/camera/latest", "/api/camera/snapshot"):
            return self.static(OUT / "recording", "snapshot.jpg")
        if path == "/api/camera/out-of-house":
            if method == "POST":
                STATE.armed = bool(json.loads(self.body() or b"{}").get("armed"))
            return self.send_json(200, {"armed": STATE.armed})
        if path == "/api/camera/events":
            return self.send_json(200, STATE.workspace_events)
        parts = [p for p in path.split("/") if p]
        if len(parts) == 6 and parts[:3] == ["api", "camera", "events"] and parts[4] == "media":
            if any(e["event_id"] == parts[3] for e in STATE.workspace_events) and parts[5] == "recording.mp4":
                return self.static(OUT / "recording", "export.mp4")
        return self.send_json(404, {"detail": "not found"})

    # -- fake ONVIF device and media services
    def onvif(self, path):
        xml = self.body().decode("utf-8", "replace")
        host = self.host()
        if "GetSystemDateAndTime" in xml:
            t = datetime.now(timezone.utc)
            return self.send_bytes(200, soap(
                f"<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:UTCDateTime><tt:Time><tt:Hour>{t.hour}</tt:Hour>"
                f"<tt:Minute>{t.minute}</tt:Minute><tt:Second>{t.second}</tt:Second></tt:Time><tt:Date><tt:Year>{t.year}</tt:Year>"
                f"<tt:Month>{t.month}</tt:Month><tt:Day>{t.day}</tt:Day></tt:Date></tt:UTCDateTime></tds:SystemDateAndTime>"
                "</tds:GetSystemDateAndTimeResponse>"), "application/soap+xml")
        if not wsse_ok(xml):
            return self.send_bytes(400, soap('<s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>ter:NotAuthorized</s:Value>'
                                             '</s:Subcode></s:Code><s:Reason><s:Text xml:lang="en">Sender not Authorized</s:Text></s:Reason></s:Fault>'),
                                   "application/soap+xml")
        if "GetDeviceInformation" in xml:
            return self.send_bytes(200, soap("<tds:GetDeviceInformationResponse><tds:Manufacturer>Fixture</tds:Manufacturer>"
                                             "<tds:Model>Test Camera</tds:Model><tds:FirmwareVersion>1.0</tds:FirmwareVersion>"
                                             "<tds:SerialNumber>FX-0001</tds:SerialNumber><tds:HardwareId>fx</tds:HardwareId>"
                                             "</tds:GetDeviceInformationResponse>"), "application/soap+xml")
        if "GetCapabilities" in xml:
            # Report an internal address, as cameras behind NAT do.
            return self.send_bytes(200, soap("<tds:GetCapabilitiesResponse><tds:Capabilities><tt:Media><tt:XAddr>"
                                             "http://192.0.2.10/onvif/media_service</tt:XAddr></tt:Media></tds:Capabilities>"
                                             "</tds:GetCapabilitiesResponse>"), "application/soap+xml")
        if "GetProfiles" in xml:
            profiles = "".join(
                f'<trt:Profiles token="{tok}" fixed="true"><tt:Name>{name}</tt:Name><tt:VideoEncoderConfiguration token="v{tok}">'
                f"<tt:Encoding>{enc}</tt:Encoding><tt:Resolution><tt:Width>{w}</tt:Width><tt:Height>{h}</tt:Height></tt:Resolution>"
                f"<tt:RateControl><tt:FrameRateLimit>10</tt:FrameRateLimit></tt:RateControl></tt:VideoEncoderConfiguration></trt:Profiles>"
                for tok, name, enc, w, h, _ in ONVIF_PROFILES)
            return self.send_bytes(200, soap(f"<trt:GetProfilesResponse>{profiles}</trt:GetProfilesResponse>"), "application/soap+xml")
        if "GetStreamUri" in xml:
            stream = next((p[5] for p in ONVIF_PROFILES if f">{p[0]}<" in xml), "fixture")
            return self.send_bytes(200, soap(f"<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://192.0.2.10:8554/{stream}</tt:Uri>"
                                             "</trt:MediaUri></trt:GetStreamUriResponse>"), "application/soap+xml")
        if "GetSnapshotUri" in xml:
            return self.send_bytes(200, soap(f"<trt:GetSnapshotUriResponse><trt:MediaUri><tt:Uri>http://{host}:{self.server.server_port}/snapshot.jpg"
                                             "</tt:Uri></trt:MediaUri></trt:GetSnapshotUriResponse>"), "application/soap+xml")
        return self.send_bytes(400, soap("<s:Fault><s:Reason><s:Text>Unsupported</s:Text></s:Reason></s:Fault>"), "application/soap+xml")


def main():
    global STATE
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8796)
    args = parser.parse_args()
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg is required (brew install ffmpeg)")

    OUT.mkdir(exist_ok=True)
    make_recordings()
    start_live_hls()
    STATE = DisposableState()

    def shutdown(*_):
        for p in PROCESSES:
            p.kill()
        os._exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(f"Fixture server on http://{args.host}:{args.port} (HLS, MJPEG, fake Frigate/go2rtc/Workspace/ONVIF)", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
