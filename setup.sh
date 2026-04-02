#!/usr/bin/env python3
"""
RPi Link v4 — WiFi Hotspot Remote Desktop
- Hidden WiFi hotspot via USB adapter (hostapd)
- MJPEG screen streaming
- Full mouse / touch / Apple Pencil input injection
- Keyboard input + clipboard sync
- Bidirectional file manager
- Terminal (limited commands)
- System stats + process manager
- System controls (reboot/shutdown/sleep)
- Screen recording (ffmpeg → file)
- Notification injection
"""

import os, io, time, json, subprocess, threading, base64, glob, shutil, mimetypes, signal
import asyncio
from pathlib import Path
from flask import (Flask, Response, jsonify, send_from_directory,
                   request, stream_with_context, abort, send_file)
from flask_sock import Sock
import simple_websocket

app  = Flask(__name__, static_folder='static')
sock = Sock(app)

# ── Load config ────────────────────────────────────────────
CONFIG_PATH = Path(__file__).parent / 'config.json'
try:
    with open(CONFIG_PATH) as f:
        CONFIG = json.load(f)
except Exception:
    CONFIG = {
        "hotspot_iface": "wlan1",
        "hotspot_ip":    "10.42.0.1",
        "hotspot_ssid":  "RPiLink",
        "server_port":   80
    }

DISPLAY    = os.environ.get("DISPLAY", ":0")
AUDIO_DEV  = os.environ.get("AUDIO_DEV", "default")
UPLOAD_DIR = Path("/tmp/rpi-uploads")
UPLOAD_DIR.mkdir(exist_ok=True)
RECORDINGS_DIR = Path("/tmp/rpi-recordings")
RECORDINGS_DIR.mkdir(exist_ok=True)

# ── Helpers ────────────────────────────────────────────────

def run(cmd, shell=True, timeout=8):
    try:
        return subprocess.check_output(
            cmd, shell=shell, stderr=subprocess.DEVNULL, timeout=timeout
        ).decode().strip()
    except Exception:
        return ""

def get_display_res():
    raw = run(f"DISPLAY={DISPLAY} xdpyinfo 2>/dev/null | grep dimensions | awk '{{print $2}}'")
    if raw and 'x' in raw:
        w, h = raw.split('x')
        return int(w), int(h)
    return 1920, 1080

# ── System stats ───────────────────────────────────────────

def cpu_temp():
    raw = run("vcgencmd measure_temp 2>/dev/null")
    if "temp=" in raw:
        return raw.replace("temp=","").replace("'C","")
    for zone in ["/sys/class/thermal/thermal_zone0/temp",
                 "/sys/class/thermal/thermal_zone1/temp"]:
        try:
            return str(round(int(open(zone).read().strip()) / 1000, 1))
        except Exception:
            continue
    return "N/A"

def pi_model():
    try:
        return open("/proc/device-tree/model").read().replace('\x00','').strip()
    except Exception:
        return "Raspberry Pi"

def cpu_percent():
    return run("top -bn1 | grep 'Cpu(s)' | awk '{print $2+$4}'") or "0"

def mem_info():
    raw = run("free -m | awk 'NR==2{print $2,$3,$4}'").split()
    if len(raw) == 3:
        total, used, free = raw
        return {"total": total, "used": used, "free": free,
                "pct": round(int(used) / int(total) * 100, 1)}
    return {"total":"?","used":"?","free":"?","pct":0}

def disk_info():
    raw = run("df -h / | awk 'NR==2{print $2,$3,$4,$5}'").split()
    if len(raw) == 4:
        return {"total": raw[0], "used": raw[1], "free": raw[2], "pct": raw[3]}
    return {"total":"?","used":"?","free":"?","pct":"?"}

def processes():
    raw = run("ps aux --sort=-%cpu | head -12 | tail -11")
    procs = []
    for line in raw.splitlines():
        parts = line.split(None, 10)
        if len(parts) >= 11:
            procs.append({
                "pid":  parts[1],
                "user": parts[0],
                "cpu":  parts[2],
                "mem":  parts[3],
                "cmd":  parts[10][:50]
            })
    return procs

def net_stats():
    iface = CONFIG.get("hotspot_iface", "wlan1")
    r = run(f"cat /proc/net/dev | grep {iface}")
    if r:
        p = r.split()
        try:
            return {"rx": p[1], "tx": p[9], "iface": iface}
        except:
            pass
    return {"rx":"0","tx":"0","iface": iface}

def hotspot_clients():
    """Return list of connected clients via ARP or dnsmasq leases."""
    clients = []
    # dnsmasq leases file
    for lease_file in ["/var/lib/misc/dnsmasq.leases", "/tmp/dnsmasq.leases"]:
        if os.path.exists(lease_file):
            for line in open(lease_file).readlines():
                parts = line.strip().split()
                if len(parts) >= 4:
                    clients.append({"mac": parts[1], "ip": parts[2], "name": parts[3]})
            if clients:
                return clients
    # Fallback: ARP table
    arp = run("arp -n 2>/dev/null | grep -v incomplete | tail -10")
    for line in arp.splitlines():
        parts = line.split()
        if len(parts) >= 3 and '.' in parts[0]:
            clients.append({"ip": parts[0], "mac": parts[2], "name": "?"})
    return clients

# ── Clipboard ──────────────────────────────────────────────

def get_clipboard():
    for tool in ["xclip -selection clipboard -o", "xsel --clipboard --output"]:
        result = run(f"DISPLAY={DISPLAY} {tool}")
        if result is not None:
            return result
    return ""

def set_clipboard(text):
    env = f"DISPLAY={DISPLAY}"
    for cmd in [f"echo '{text}' | DISPLAY={DISPLAY} xclip -selection clipboard",
                f"echo '{text}' | DISPLAY={DISPLAY} xsel --clipboard --input"]:
        try:
            subprocess.run(cmd, shell=True, timeout=3)
            return True
        except:
            continue
    return False

# ── Screen recording ───────────────────────────────────────
_recording_proc = None
_recording_file = None

def start_recording():
    global _recording_proc, _recording_file
    if _recording_proc and _recording_proc.poll() is None:
        return {"ok": False, "error": "Already recording"}
    ts = time.strftime("%Y%m%d_%H%M%S")
    _recording_file = str(RECORDINGS_DIR / f"recording_{ts}.mp4")
    w, h = get_display_res()
    cmd = [
        "ffmpeg", "-loglevel", "quiet",
        "-f", "x11grab", "-framerate", "15",
        "-video_size", f"{w}x{h}",
        "-i", f"{DISPLAY}.0+0,0",
        "-c:v", "libx264", "-preset", "ultrafast",
        "-pix_fmt", "yuv420p",
        _recording_file
    ]
    _recording_proc = subprocess.Popen(cmd)
    return {"ok": True, "file": _recording_file}

def stop_recording():
    global _recording_proc, _recording_file
    if not _recording_proc or _recording_proc.poll() is not None:
        return {"ok": False, "error": "Not recording"}
    _recording_proc.send_signal(signal.SIGINT)
    _recording_proc.wait(timeout=10)
    f = _recording_file
    _recording_proc = None
    _recording_file = None
    return {"ok": True, "file": f}

# ── Video streaming ────────────────────────────────────────
_ffmpeg_proc  = None
_latest_frame = None
_frame_lock   = threading.Lock()
_frame_cond   = threading.Condition(_frame_lock)

def ffmpeg_capture_loop(fps=24, width=1280, quality=4):
    global _ffmpeg_proc, _latest_frame
    disp_w, disp_h = get_display_res()
    scale_h = int(disp_h * width / disp_w)
    cmd = [
        "ffmpeg", "-loglevel", "quiet",
        "-f", "x11grab",
        "-framerate", str(fps),
        "-video_size", f"{disp_w}x{disp_h}",
        "-i", f"{DISPLAY}.0+0,0",
        "-vf", f"scale={width}:{scale_h}:flags=lanczos",
        "-f", "image2pipe",
        "-vcodec", "mjpeg",
        "-q:v", str(quality),
        "pipe:1"
    ]
    _ffmpeg_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    buf = b""
    SOI = b"\xff\xd8"
    EOI = b"\xff\xd9"
    while True:
        chunk = _ffmpeg_proc.stdout.read(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            start = buf.find(SOI)
            if start == -1:
                buf = b""
                break
            end = buf.find(EOI, start + 2)
            if end == -1:
                buf = buf[start:]
                break
            frame = buf[start:end + 2]
            buf   = buf[end + 2:]
            with _frame_cond:
                _latest_frame = frame
                _frame_cond.notify_all()

_capture_settings = {"fps": 24, "width": 1280, "quality": 4}

def restart_capture(**kwargs):
    global _ffmpeg_proc
    _capture_settings.update(kwargs)
    if _ffmpeg_proc:
        _ffmpeg_proc.terminate()
        _ffmpeg_proc = None
    t = threading.Thread(target=ffmpeg_capture_loop, kwargs=_capture_settings, daemon=True)
    t.start()

restart_capture()

def get_frame(timeout=1.0):
    with _frame_cond:
        _frame_cond.wait(timeout)
        return _latest_frame

# ── Audio streaming ────────────────────────────────────────
_audio_clients = set()
_audio_lock    = threading.Lock()

def audio_broadcast_loop():
    cmd = [
        "ffmpeg", "-loglevel", "quiet",
        "-f", "pulse", "-i", "default",
        "-ac", "2", "-ar", "44100",
        "-f", "s16le", "pipe:1"
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if proc.poll() is not None:
        cmd[3] = "alsa"
        cmd[5] = AUDIO_DEV
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    CHUNK = 4096
    while True:
        data = proc.stdout.read(CHUNK)
        if not data:
            break
        with _audio_lock:
            dead = set()
            for ws in list(_audio_clients):
                try:
                    ws.send(data)
                except Exception:
                    dead.add(ws)
            _audio_clients -= dead

threading.Thread(target=audio_broadcast_loop, daemon=True).start()

# ── Input injection ────────────────────────────────────────

def inject_mouse(action, x, y, button=1, dy=0, stream_w=1280):
    disp_w, disp_h = get_display_res()
    stream_h = int(disp_h * stream_w / disp_w)
    rx = max(0, min(int(x * disp_w / stream_w), disp_w - 1))
    ry = max(0, min(int(y * disp_h / stream_h), disp_h - 1))
    env = {"DISPLAY": DISPLAY}
    base = ["xdotool"]
    if action == "move":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry)], env=env, stderr=subprocess.DEVNULL)
    elif action == "down":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry), "mousedown", str(button)], env=env, stderr=subprocess.DEVNULL)
    elif action == "up":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry), "mouseup", str(button)], env=env, stderr=subprocess.DEVNULL)
    elif action == "click":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry), "click", str(button)], env=env, stderr=subprocess.DEVNULL)
    elif action == "dblclick":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry), "click", "--repeat", "2", "--delay", "50", str(button)], env=env, stderr=subprocess.DEVNULL)
    elif action == "scroll":
        btn = "4" if dy < 0 else "5"
        subprocess.Popen(base + ["mousemove", str(rx), str(ry), "click", "--repeat", "3", btn], env=env, stderr=subprocess.DEVNULL)
    elif action == "rclick":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry), "click", "3"], env=env, stderr=subprocess.DEVNULL)

def inject_key(key):
    subprocess.Popen(["xdotool", "key", "--", key], env={"DISPLAY": DISPLAY}, stderr=subprocess.DEVNULL)

def inject_type(text):
    subprocess.Popen(["xdotool", "type", "--clearmodifiers", "--", text],
                     env={"DISPLAY": DISPLAY}, stderr=subprocess.DEVNULL)

# ── Routes: Video ──────────────────────────────────────────

@app.route("/")
def index():
    return send_from_directory("static", "index.html")

@app.route("/api/stream")
def stream():
    fps_limit = float(request.args.get("fps", 24))
    interval  = 1.0 / fps_limit

    def generate():
        last = 0
        while True:
            frame = get_frame(timeout=2.0)
            if not frame:
                continue
            now = time.time()
            if now - last < interval:
                continue
            last = now
            yield (
                b"--frame\r\n"
                b"Content-Type: image/jpeg\r\n\r\n" + frame + b"\r\n"
            )

    return Response(stream_with_context(generate()),
                    mimetype="multipart/x-mixed-replace; boundary=frame",
                    headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})

@app.route("/api/screenshot")
def screenshot():
    frame = _latest_frame
    if not frame:
        return Response("no frame", status=503)
    return Response(frame, mimetype="image/jpeg",
                    headers={"Cache-Control": "no-store"})

@app.route("/api/stream/settings", methods=["POST"])
def stream_settings():
    body  = request.get_json(silent=True) or {}
    fps   = int(body.get("fps",  24))
    qual  = int(body.get("quality", 4))
    w     = int(body.get("width", 1280))
    restart_capture(fps=fps, quality=qual, width=w)
    return jsonify({"ok": True})

# ── Routes: Audio ──────────────────────────────────────────

@sock.route("/ws/audio")
def audio_ws(ws):
    with _audio_lock:
        _audio_clients.add(ws)
    try:
        while True:
            ws.receive(timeout=60)
    except Exception:
        pass
    finally:
        with _audio_lock:
            _audio_clients.discard(ws)

# ── Routes: Input ──────────────────────────────────────────

@app.route("/api/input/mouse", methods=["POST"])
def input_mouse():
    body   = request.get_json(silent=True) or {}
    action = body.get("action", "move")
    x      = float(body.get("x", 0))
    y      = float(body.get("y", 0))
    btn    = int(body.get("button", 1))
    dy     = float(body.get("dy", 0))
    sw     = int(body.get("streamW", 1280))
    inject_mouse(action, x, y, btn, dy, sw)
    return jsonify({"ok": True})

@app.route("/api/input/key", methods=["POST"])
def input_key():
    body = request.get_json(silent=True) or {}
    key  = body.get("key", "")
    if key:
        inject_key(key)
    return jsonify({"ok": True})

@app.route("/api/input/type", methods=["POST"])
def input_type():
    body = request.get_json(silent=True) or {}
    text = body.get("text", "")
    if text:
        inject_type(text)
    return jsonify({"ok": True})

# ── Routes: Clipboard ──────────────────────────────────────

@app.route("/api/clipboard", methods=["GET"])
def clipboard_get():
    return jsonify({"text": get_clipboard()})

@app.route("/api/clipboard", methods=["POST"])
def clipboard_set():
    body = request.get_json(silent=True) or {}
    text = body.get("text", "")
    ok   = set_clipboard(text)
    return jsonify({"ok": ok})

# ── Routes: Files ──────────────────────────────────────────

ALLOWED_BROWSE_ROOTS = [
    Path.home(),
    Path("/tmp"),
    Path("/media"),
    Path("/mnt"),
    RECORDINGS_DIR,
]

def safe_path(raw):
    p = Path(raw).resolve()
    for root in ALLOWED_BROWSE_ROOTS:
        try:
            p.relative_to(root.resolve())
            return p
        except ValueError:
            continue
    return None

@app.route("/api/files/list")
def files_list():
    raw  = request.args.get("path", str(Path.home()))
    path = safe_path(raw)
    if not path or not path.exists():
        return jsonify({"error": "Invalid path"}), 400
    entries = []
    try:
        for item in sorted(path.iterdir(), key=lambda x: (x.is_file(), x.name.lower())):
            stat = item.stat()
            entries.append({
                "name":     item.name,
                "path":     str(item),
                "is_dir":   item.is_dir(),
                "size":     stat.st_size if item.is_file() else 0,
                "modified": int(stat.st_mtime),
                "mime":     mimetypes.guess_type(item.name)[0] or "",
            })
    except PermissionError:
        return jsonify({"error": "Permission denied"}), 403
    return jsonify({"path": str(path), "parent": str(path.parent), "entries": entries})

@app.route("/api/files/download")
def files_download():
    raw  = request.args.get("path", "")
    path = safe_path(raw)
    if not path or not path.is_file():
        return jsonify({"error": "Not a file"}), 404
    return send_from_directory(str(path.parent), path.name, as_attachment=True)

@app.route("/api/files/upload", methods=["POST"])
def files_upload():
    dest_raw = request.args.get("dest", str(Path.home()))
    dest     = safe_path(dest_raw)
    if not dest or not dest.is_dir():
        return jsonify({"error": "Invalid destination"}), 400
    saved = []
    for f in request.files.values():
        name = Path(f.filename).name
        out  = dest / name
        f.save(str(out))
        saved.append(name)
    return jsonify({"ok": True, "saved": saved})

@app.route("/api/files/mkdir", methods=["POST"])
def files_mkdir():
    body = request.get_json(silent=True) or {}
    dest = safe_path(body.get("path", ""))
    if not dest:
        return jsonify({"error": "Invalid path"}), 400
    dest.mkdir(parents=True, exist_ok=True)
    return jsonify({"ok": True})

@app.route("/api/files/delete", methods=["POST"])
def files_delete():
    body = request.get_json(silent=True) or {}
    path = safe_path(body.get("path", ""))
    if not path or not path.exists():
        return jsonify({"error": "Not found"}), 404
    if path.is_dir():
        shutil.rmtree(str(path))
    else:
        path.unlink()
    return jsonify({"ok": True})

@app.route("/api/files/rename", methods=["POST"])
def files_rename():
    body     = request.get_json(silent=True) or {}
    src      = safe_path(body.get("src", ""))
    new_name = Path(body.get("name", "")).name
    if not src or not src.exists() or not new_name:
        return jsonify({"error": "Invalid"}), 400
    dst = src.parent / new_name
    src.rename(dst)
    return jsonify({"ok": True})

# ── Routes: Recording ──────────────────────────────────────

@app.route("/api/record/start", methods=["POST"])
def record_start():
    return jsonify(start_recording())

@app.route("/api/record/stop", methods=["POST"])
def record_stop():
    return jsonify(stop_recording())

@app.route("/api/record/status")
def record_status():
    recording = _recording_proc is not None and _recording_proc.poll() is None
    return jsonify({"recording": recording, "file": _recording_file})

# ── Routes: System ─────────────────────────────────────────

@app.route("/api/stats")
def stats():
    mem  = mem_info()
    disk = disk_info()
    iface = CONFIG.get("hotspot_iface", "wlan1")
    hotspot_ip = run(f"ip addr show {iface} 2>/dev/null | grep 'inet ' | awk '{{print $2}}'") or "not up"
    return jsonify({
        "hostname":  run("hostname"),
        "model":     pi_model(),
        "uptime":    run("uptime -p").replace("up ", ""),
        "cpu":       cpu_percent(),
        "temp":      cpu_temp(),
        "mem":       mem,
        "disk":      disk,
        "hotspot_ip": hotspot_ip,
        "hotspot_iface": iface,
        "net":       net_stats(),
        "processes": processes(),
        "clients":   hotspot_clients(),
        "time":      time.strftime("%H:%M:%S"),
        "date":      time.strftime("%A %d %B %Y"),
        "display":   "%dx%d" % get_display_res(),
        "stream":    _capture_settings,
        "recording": _recording_proc is not None and _recording_proc.poll() is None,
    })

@app.route("/api/process/kill", methods=["POST"])
def process_kill():
    body = request.get_json(silent=True) or {}
    pid  = int(body.get("pid", 0))
    sig  = body.get("signal", "TERM")
    if not pid:
        return jsonify({"error": "No PID"}), 400
    try:
        os.kill(pid, signal.SIGTERM if sig == "TERM" else signal.SIGKILL)
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/system/reboot", methods=["POST"])
def system_reboot():
    threading.Timer(2.0, lambda: subprocess.run(["reboot"])).start()
    return jsonify({"ok": True, "message": "Rebooting in 2s…"})

@app.route("/api/system/shutdown", methods=["POST"])
def system_shutdown():
    threading.Timer(2.0, lambda: subprocess.run(["shutdown", "-h", "now"])).start()
    return jsonify({"ok": True, "message": "Shutting down in 2s…"})

@app.route("/api/system/sleep", methods=["POST"])
def system_sleep():
    subprocess.Popen(["systemctl", "suspend"])
    return jsonify({"ok": True})

BLOCKED = ["rm -rf /", "mkfs", "dd if=", "fork bomb", ":(){ :|:& };:"]

@app.route("/api/run", methods=["POST"])
def run_cmd():
    body = request.get_json(silent=True) or {}
    cmd  = body.get("cmd", "").strip()
    if any(b in cmd for b in BLOCKED):
        return jsonify({"error": "Command blocked"}), 403
    if not cmd:
        return jsonify({"output": ""})
    out = run(cmd, timeout=15)
    return jsonify({"output": out or "(no output)"})

# ── Routes: Hotspot info ───────────────────────────────────

@app.route("/api/hotspot")
def hotspot_info():
    return jsonify({
        "ssid":    CONFIG.get("hotspot_ssid", "RPiLink"),
        "iface":   CONFIG.get("hotspot_iface", "wlan1"),
        "ip":      CONFIG.get("hotspot_ip", "10.42.0.1"),
        "clients": hotspot_clients(),
        "hostapd_running": run("systemctl is-active hostapd") == "active",
    })

# ── Main ───────────────────────────────────────────────────

if __name__ == "__main__":
    port = CONFIG.get("server_port", 80)
    print(f"RPi Link v4 → http://0.0.0.0:{port}")
    app.run(host="0.0.0.0", port=port, debug=False, threaded=True)
