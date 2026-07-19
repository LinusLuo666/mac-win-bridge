#!/usr/bin/env python3
import html
import json
import math
import os
import signal
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parents[1]
STATE_DIR = ROOT / ".runtime" / "audio-bridge"
PID_FILE = STATE_DIR / "mac-audio.pid"
LOG_FILE = STATE_DIR / "mac-audio.log"
CONFIG_FILE = STATE_DIR / "config.json"
DEFAULT_HOST = "192.168.1.13"
DEFAULT_PORT = 5055
DEFAULT_LATENCY_MS = 50
MIN_LATENCY_MS = 10
MAX_LATENCY_MS = 120
MANAGER_PORT = int(os.environ.get("AUDIO_BRIDGE_MANAGER_PORT", "8765"))


def ensure_state_dir():
    STATE_DIR.mkdir(parents=True, exist_ok=True)


def valid_latency_ms(value):
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        return DEFAULT_LATENCY_MS
    if isinstance(value, str) and not value.strip().isdigit():
        return DEFAULT_LATENCY_MS
    try:
        latency = int(value)
    except (TypeError, ValueError):
        return DEFAULT_LATENCY_MS
    return latency if MIN_LATENCY_MS <= latency <= MAX_LATENCY_MS else DEFAULT_LATENCY_MS


def effective_latency_ms(latency_ms, sample_rate=48_000, block_frames=512):
    target_frames = math.ceil(sample_rate * latency_ms / 1_000 / block_frames) * block_frames
    return target_frames * 1_000 / sample_rate


def load_config():
    if not CONFIG_FILE.exists():
        return {
            "host": DEFAULT_HOST,
            "port": DEFAULT_PORT,
            "latency_ms": DEFAULT_LATENCY_MS,
        }
    try:
        data = json.loads(CONFIG_FILE.read_text())
        return {
            "host": str(data.get("host") or DEFAULT_HOST),
            "port": int(data.get("port") or DEFAULT_PORT),
            "latency_ms": valid_latency_ms(data.get("latency_ms")),
        }
    except (OSError, ValueError, TypeError):
        return {
            "host": DEFAULT_HOST,
            "port": DEFAULT_PORT,
            "latency_ms": DEFAULT_LATENCY_MS,
        }


def save_config(host, port, latency_ms):
    ensure_state_dir()
    CONFIG_FILE.write_text(
        json.dumps(
            {
                "host": host,
                "port": port,
                "latency_ms": valid_latency_ms(latency_ms),
            },
            indent=2,
        )
        + "\n"
    )


def process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def managed_pid():
    try:
        pid = int(PID_FILE.read_text().strip())
    except (OSError, ValueError):
        return None
    return pid if process_alive(pid) else None


def detect_audio_processes():
    try:
        output = subprocess.check_output(["pgrep", "-fl", "mac-controller"], text=True)
    except subprocess.CalledProcessError:
        return []
    processes = []
    for line in output.splitlines():
        if "--audio-only" in line or "start-mac-audio.sh" in line:
            processes.append(line)
    return processes


def tcp_status(host, port, timeout=1.0):
    start = time.time()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, f"reachable in {time.time() - start:.2f}s"
    except OSError as error:
        return False, str(error)


def tail_log(lines=80):
    try:
        content = LOG_FILE.read_text(errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(content[-lines:])


def start_audio(host, port, latency_ms):
    ensure_state_dir()
    latency_ms = valid_latency_ms(latency_ms)
    save_config(host, port, latency_ms)
    pid = managed_pid()
    if pid:
        return f"Mac audio is already managed by PID {pid}."

    log = LOG_FILE.open("ab", buffering=0)
    environment = os.environ.copy()
    environment["AUDIO_LATENCY_MS"] = str(latency_ms)
    process = subprocess.Popen(
        [str(ROOT / "scripts" / "start-mac-audio.sh"), host, str(port)],
        cwd=str(ROOT),
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env=environment,
    )
    PID_FILE.write_text(f"{process.pid}\n")
    return f"Started Mac audio PID {process.pid} for {host}:{port} at {latency_ms} ms."


def stop_audio():
    pid = managed_pid()
    if not pid:
        return "No managed Mac audio process is running."

    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        os.kill(pid, signal.SIGTERM)

    deadline = time.time() + 5
    while time.time() < deadline:
        if not process_alive(pid):
            break
        time.sleep(0.1)

    if process_alive(pid):
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            os.kill(pid, signal.SIGKILL)

    try:
        PID_FILE.unlink()
    except OSError:
        pass
    return f"Stopped managed Mac audio PID {pid}."


def render_page(message=""):
    config = load_config()
    effective_latency = effective_latency_ms(config["latency_ms"])
    pid = managed_pid()
    reachable, reach_message = tcp_status(config["host"], config["port"])
    detected = detect_audio_processes()
    log = tail_log()
    status_text = "running" if pid else "not managed"
    reach_text = "reachable" if reachable else "not reachable"
    windows_command = (
        "cd D:\\AAALXLXLX\\AABMac2Windows\\mac-win-bridge\n"
        "dotnet run --project windows-agent\\src\\WindowsAgent\\WindowsAgent.csproj -- 5055"
    )
    detected_html = "\n".join(html.escape(p) for p in detected) or "none"
    message_html = f"<div class='message'>{html.escape(message)}</div>" if message else ""
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="5">
  <title>Audio Bridge Manager</title>
  <style>
    :root {{
      color-scheme: light dark;
      --bg: #f6f7f8;
      --panel: #ffffff;
      --text: #1d252d;
      --muted: #66717c;
      --line: #d7dde3;
      --accent: #0f766e;
      --danger: #b42318;
      --code: #111827;
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        --bg: #111418;
        --panel: #181d23;
        --text: #edf1f5;
        --muted: #a7b0b9;
        --line: #303842;
        --accent: #2dd4bf;
        --danger: #fb7185;
        --code: #0b0f14;
      }}
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }}
    main {{
      max-width: 980px;
      margin: 0 auto;
      padding: 28px 20px 40px;
    }}
    header {{
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 16px;
      border-bottom: 1px solid var(--line);
      padding-bottom: 14px;
      margin-bottom: 18px;
    }}
    h1 {{ font-size: 22px; margin: 0; letter-spacing: 0; }}
    h2 {{ font-size: 15px; margin: 0 0 12px; letter-spacing: 0; }}
    .grid {{
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
    }}
    section {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
    }}
    .full {{ grid-column: 1 / -1; }}
    .kv {{
      display: grid;
      grid-template-columns: 150px minmax(0, 1fr);
      gap: 8px 12px;
    }}
    .key {{ color: var(--muted); }}
    .value {{ font-weight: 600; word-break: break-word; }}
    form {{
      display: grid;
      grid-template-columns: 1fr 110px auto auto;
      gap: 10px;
      align-items: end;
    }}
    label {{ color: var(--muted); display: grid; gap: 4px; }}
    .latency-control {{
      grid-column: 1 / -1;
      display: grid;
      grid-template-columns: minmax(180px, 1fr) 100px auto;
      gap: 10px;
      align-items: end;
    }}
    .latency-presets {{ display: flex; gap: 6px; flex-wrap: wrap; }}
    .latency-note {{ color: var(--muted); margin-top: 6px; }}
    input {{
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 9px 10px;
      background: transparent;
      color: var(--text);
      font: inherit;
    }}
    button {{
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 9px 12px;
      font: inherit;
      color: var(--text);
      background: transparent;
      cursor: pointer;
      min-height: 38px;
    }}
    button.primary {{
      border-color: var(--accent);
      background: var(--accent);
      color: #ffffff;
    }}
    button.danger {{ border-color: var(--danger); color: var(--danger); }}
    pre {{
      margin: 0;
      padding: 12px;
      border-radius: 6px;
      background: var(--code);
      color: #d7e1ea;
      overflow: auto;
      white-space: pre-wrap;
      word-break: break-word;
      min-height: 46px;
    }}
    .message {{
      border: 1px solid var(--accent);
      border-radius: 6px;
      padding: 10px 12px;
      margin-bottom: 14px;
      color: var(--accent);
      background: color-mix(in srgb, var(--accent) 10%, transparent);
    }}
    @media (max-width: 760px) {{
      .grid {{ grid-template-columns: 1fr; }}
      form {{ grid-template-columns: 1fr; }}
      .latency-control {{ grid-template-columns: 1fr; }}
      header {{ display: block; }}
    }}
  </style>
</head>
<body>
<main>
  <header>
    <h1>Audio Bridge Manager</h1>
    <div class="key">refreshes every 5 seconds</div>
  </header>
  {message_html}
  <div class="grid">
    <section>
      <h2>Status</h2>
      <div class="kv">
        <div class="key">Managed Mac audio</div><div class="value">{html.escape(status_text)}</div>
        <div class="key">Managed PID</div><div class="value">{html.escape(str(pid) if pid else "-")}</div>
        <div class="key">Windows target</div><div class="value">{html.escape(config["host"])}:{config["port"]}</div>
        <div class="key">Audio latency</div><div class="value">{config["latency_ms"]} ms requested / {effective_latency:.1f} ms effective</div>
        <div class="key">Port check</div><div class="value">{html.escape(reach_text)} ({html.escape(reach_message)})</div>
      </div>
    </section>
    <section>
      <h2>Mac Control</h2>
      <form method="post" action="/start">
        <label>Windows host<input name="host" value="{html.escape(config["host"])}"></label>
        <label>Port<input name="port" value="{config["port"]}" inputmode="numeric"></label>
        <button class="primary" type="submit">Start</button>
        <button class="danger" type="submit" formaction="/stop">Stop</button>
        <div class="latency-control">
          <label>Latency balance
            <input id="latency-range" type="range" name="latency_range" min="10" max="120" step="1" value="{config["latency_ms"]}">
          </label>
          <label>Milliseconds
            <input id="latency-number" name="latency_ms" type="number" min="10" max="120" step="1" value="{config["latency_ms"]}">
          </label>
          <div class="latency-presets">
            <button type="button" data-latency="20">20 ms</button>
            <button type="button" data-latency="50">50 ms</button>
            <button type="button" data-latency="80">80 ms</button>
          </div>
        </div>
        <div id="latency-effective" class="latency-note full">{effective_latency:.1f} ms effective after 512-frame rounding at 48 kHz</div>
      </form>
    </section>
    <section class="full">
      <h2>Windows Command</h2>
      <pre>{html.escape(windows_command)}</pre>
    </section>
    <section class="full">
      <h2>Detected Mac Audio Processes</h2>
      <pre>{detected_html}</pre>
    </section>
    <section class="full">
      <h2>Mac Audio Log</h2>
      <pre>{html.escape(log)}</pre>
    </section>
  </div>
</main>
<script>
  const range = document.getElementById("latency-range");
  const number = document.getElementById("latency-number");
  const effective = document.getElementById("latency-effective");
  function updateLatency(value) {{
    const latency = Math.min(120, Math.max(10, Number(value) || 50));
    range.value = latency;
    number.value = latency;
    const frames = Math.ceil(48000 * latency / 1000 / 512) * 512;
    effective.textContent = `${{(frames * 1000 / 48000).toFixed(1)}} ms effective after 512-frame rounding at 48 kHz`;
  }}
  range.addEventListener("input", event => updateLatency(event.target.value));
  number.addEventListener("input", event => updateLatency(event.target.value));
  document.querySelectorAll("[data-latency]").forEach(button => {{
    button.addEventListener("click", () => updateLatency(button.dataset.latency));
  }});
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.respond(render_page())

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length).decode()
        data = parse_qs(body)
        config = load_config()
        host = data.get("host", [config["host"]])[0].strip() or config["host"]
        try:
            port = int(data.get("port", [str(config["port"])])[0])
        except ValueError:
            port = config["port"]
        latency_ms = valid_latency_ms(
            data.get("latency_ms", [str(config["latency_ms"])])[0]
        )

        if self.path == "/start":
            message = start_audio(host, port, latency_ms)
        elif self.path == "/stop":
            message = stop_audio()
            save_config(host, port, latency_ms)
        else:
            self.send_error(404)
            return
        self.respond(render_page(message))

    def respond(self, body):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    ensure_state_dir()
    load_config()
    server = ThreadingHTTPServer(("127.0.0.1", MANAGER_PORT), Handler)
    print(f"Audio Bridge Manager: http://127.0.0.1:{MANAGER_PORT}")
    print(f"Repo: {ROOT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
