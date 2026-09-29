#!/usr/bin/env python3
"""sevobench — repeatable measurements of what Sevoflurane costs.

Three scenarios, each written as one JSON line per run so runs from different
builds can be compared later with `report`:

  launch   cold start: quit the app, open it, time until `sevo status` says
           healthy; the boot milestones from the app log; CPU seconds the app
           and the daemon spent getting there.
  idle     the app healthy and no game running: per-process CPU and memory
           over a quiet window. CPU is measured from cputime deltas, not the
           decayed %CPU column, so a 60 s window is exact to the tick.
  game     one game under the engine: time to its window, time to its first
           presented frame, presents per second once it is up, and the CPU,
           GPU and memory it and the engine cost while it runs.

Stdlib only. Drives `sevo` and the control port; reads the app log and the
Wine log the way the report zip does. Run it from a terminal that is not the
frontmost app if `game` needs the window in front (it does not).
"""
import argparse, json, os, re, statistics, subprocess, sys, time, urllib.request
from datetime import datetime, timezone
from pathlib import Path

SEVO = os.environ.get("SEVO", "/Applications/Sevoflurane.app/Contents/Helpers/sevo")
APP_LOG = Path.home() / "Library/Logs/Sevoflurane.log"
WINE_LOG = Path.home() / "Library/Logs/Sevoflurane-wine.log"
OUT_DIR = Path(os.environ.get("SEVOBENCH_OUT", Path.home() / "Library/Application Support/Sevoflurane/Bench"))
CONTROL = "http://localhost:8764"
# The control port answers 401 without this account's token (Core/ControlToken.swift).
CONTROL_TOKEN = Path.home() / "Library/Application Support/Sevoflurane/Control/token"
BOTTLE_PATH = re.compile(r"/(Sevoflurane|CrossOver)/Bottles/")
BOTTLE_PATTERN = re.compile(r"Sevoflurane|SevofluraneDaemon|wineserver|\.exe|wine64-preloader|wine-preloader", re.I)


def sh(*args, timeout=120, check=False):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise SystemExit(f"{' '.join(args)} failed: {p.stderr.strip() or p.stdout.strip()}")
    return p.stdout


def sevo_status():
    try:
        return json.loads(sh(SEVO, "status", "--json", timeout=20))
    except (json.JSONDecodeError, subprocess.TimeoutExpired):
        return {}


def health():
    return (sevo_status().get("app") or {}).get("health", "?")


def control(path, method="GET"):
    # In a header, never on a command line: another account can read any
    # process's arguments with ps.
    try:
        token = CONTROL_TOKEN.read_text().strip()
    except OSError:
        token = ""
    request = urllib.request.Request(CONTROL + path, method=method, headers={"X-Sevo-Token": token})
    try:
        with urllib.request.urlopen(request, timeout=3) as reply:
            out = reply.read().decode()
    except OSError:
        out = ""
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"raw": out}


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def host():
    load = os.getloadavg()[0]
    therm = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", sh("pmset", "-g", "therm"))
    st = sevo_status()
    return {
        "load1m": round(load, 2),
        "cpu_speed_limit": int(therm.group(1)) if therm else None,
        "macos": sh("sw_vers", "-productVersion").strip(),
        "chip": sh("sysctl", "-n", "machdep.cpu.brand_string").strip(),
        "app": (st.get("app") or {}).get("version"),
        "engine": st.get("engine"),
        "debug": (st.get("app") or {}).get("debug"),
    }


# ---------------------------------------------------------------- processes

def procs():
    """pid -> (name, cputime_s, rss_mb) for the app, its daemon, and the Wine
    processes of the app's own bottles. A Wine process elsewhere on the machine
    (another prefix, another launcher) is not the app's cost and is skipped."""
    out = sh("ps", "-Ao", "pid=,rss=,cputime=,command=")
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        pid, rss, cput, cmd = parts
        if not BOTTLE_PATTERN.search(cmd) or "sevobench" in cmd:
            continue
        pid = int(pid)
        if not belongs_to_app(pid, cmd):
            continue
        table[pid] = (label(cmd), cputime_seconds(cput), int(rss) / 1024)
    return table


_prefix_cache = {}


def belongs_to_app(pid, cmd):
    """The app and daemon by name; a Wine process by the bottle its working
    directory sits in (its environment is not readable from here)."""
    if "Sevoflurane" in cmd:
        return True
    if pid not in _prefix_cache:
        # cwd first (one line); Steam.exe itself keeps cwd at / and is caught
        # by the files it holds open inside the bottle
        cwd = sh("lsof", "-a", "-d", "cwd", "-Fn", "-p", str(pid), timeout=10)
        hit = bool(BOTTLE_PATH.search(cwd))
        if not hit:
            files = sh("lsof", "-Fn", "-p", str(pid), timeout=20)
            hit = bool(BOTTLE_PATH.search(files))
        _prefix_cache[pid] = hit
    return _prefix_cache[pid]


def label(cmd):
    """A short name per process. Wine command lines are Windows paths with
    spaces, so the executable is everything up to the first `.exe`."""
    if re.search(r"/Sevoflurane\.app/Contents/MacOS/Sevoflurane(\s|$)", cmd):
        return "app"
    if "SevofluraneDaemon" in cmd:
        return "daemon"
    if re.search(r"(^|/)wineserver(\s|$)", cmd):
        return "wineserver"
    m = re.match(r"(.*?\.exe)(\s|$)", cmd, re.I)
    if not m:
        return cmd.split()[0].rsplit("/", 1)[-1]
    exe = m.group(1).replace("/", "\\").rsplit("\\", 1)[-1].lower()
    if exe == "steamwebhelper.exe":
        t = re.search(r"--type=(\S+)", cmd)
        return "webhelper:" + (t.group(1) if t else "browser")
    if exe == "steam.exe":
        return "steam"
    if exe == "steamservice.exe":
        return "steamservice"
    return "wine:" + exe


def cputime_seconds(s):
    # ps cputime looks like MM:SS.ss or HH:MM:SS or D-HH:MM:SS
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = [float(x) for x in s.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    h, m, sec = parts
    return days * 86400 + h * 3600 + m * 60 + sec


def gpu_utilization():
    out = sh("ioreg", "-r", "-d", "1", "-c", "IOAccelerator")
    m = re.search(r'"Device Utilization %"=(\d+)', out)
    return int(m.group(1)) if m else None


def sample_window(seconds, every=1.0, game_pid=None):
    """CPU% per process group from cputime deltas over the window, peak RSS,
    mean GPU utilization. Returns a dict the scenarios embed."""
    t0 = time.monotonic()
    start = procs()
    peak = {}
    gpu = []
    while time.monotonic() - t0 < seconds:
        time.sleep(every)
        g = gpu_utilization()
        if g is not None:
            gpu.append(g)
        for pid, (name, _, rss) in procs().items():
            peak[name] = max(peak.get(name, 0.0), rss)
    end = procs()
    elapsed = time.monotonic() - t0
    cpu = {}
    for pid, (name, cput_end, _) in end.items():
        cput_start = start.get(pid, (name, 0.0, 0.0))[1]
        cpu[name] = cpu.get(name, 0.0) + (cput_end - cput_start)
    groups = {}
    for name, secs in cpu.items():
        key = name.split(":")[0] if name.startswith(("webhelper", "wine")) else name
        groups[key] = round(groups.get(key, 0.0) + 100.0 * secs / elapsed, 2)
    return {
        "seconds": round(elapsed, 1),
        "cpu_pct": dict(sorted(groups.items())),
        "cpu_pct_total": round(sum(groups.values()), 2),
        "rss_peak_mb": {k: round(v, 1) for k, v in sorted(peak.items())},
        "rss_peak_total_mb": round(sum(peak.values()), 1),
        "gpu_pct_mean": round(statistics.mean(gpu), 1) if gpu else None,
        "gpu_pct_max": max(gpu) if gpu else None,
        "processes": len(end),
    }


# ---------------------------------------------------------------- logs

def log_offset(path):
    return path.stat().st_size if path.exists() else 0


def log_since(path, offset):
    if not path.exists():
        return ""
    with open(path, "rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


def app_milestones(text):
    """Boot milestones the app logs, as seconds after the first line seen."""
    pat = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) \[(\w+)\] (.*)$", re.M)
    first = None
    found = {}
    wanted = {
        "client_launched": "launching the bottle client",
        "client_back": "client is back",
        "services_ready": "client services ready",
        "healthy": "healthy: client, bridge, page",
        "window_opened": "opening Steam's window",
    }
    for m in pat.finditer(text):
        t = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f")
        first = first or t
        for key, needle in wanted.items():
            if key not in found and needle in m.group(3):
                found[key] = round((t - first).total_seconds(), 2)
    audit = re.search(r"boot audit: (\d+)s from launch to healthy", text)
    if audit:
        found["boot_audit_s"] = int(audit.group(1))
    return found


def gfx_lines(text, exe):
    """The engine's provenance lines for the last process running `exe`."""
    pids = re.findall(r"sevo:run pid=(\d+) exe=%s " % re.escape(exe), text)
    if not pids:
        return {}
    pid = pids[-1]
    out = {"pid": int(pid)}
    m = re.search(r"sevo:gfx pid=%s renderer=(\S+) toolkit=(.*?) presenter=(\S+) upscaler=(\S+) msync=(\S+)" % pid, text)
    if m:
        out.update(renderer=m.group(1), toolkit=m.group(2), presenter=m.group(3), upscaler=m.group(4), msync=m.group(5))
    m = re.search(r"sevo:gfx pid=%s first present \+(\d+)ms .* layer=(\S+)" % pid, text)
    if m:
        out["first_present_ms"] = int(m.group(1))
        out["layer"] = m.group(2)
    m = re.search(r"sevo:gfx pid=%s exit presents=(\d+)" % pid, text)
    if m:
        out["presents"] = int(m.group(1))
    posted = re.findall(r"sevo:gfx pid=%s d3dmetal posted=(\d+) executed=(\d+)" % pid, text)
    if len(posted) >= 2:
        # Debug mode prints one every 10 s once frames flow; the steady rate is
        # the last interval, which excludes loading.
        (p0, e0), (p1, e1) = [tuple(map(int, x)) for x in posted[-2:]]
        out["executed_per_s_last_interval"] = round((e1 - e0) / 10.0, 1)
        out["posted_per_s_last_interval"] = round((p1 - p0) / 10.0, 1)
    return out


# ---------------------------------------------------------------- scenarios

def quit_app(timeout=90):
    sh("osascript", "-e", 'tell application "Sevoflurane" to quit')
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        if not sh("pgrep", "-x", "Sevoflurane").strip() and sevo_status().get("client") == "stopped":
            return True
        time.sleep(1)
    return False


def wait_healthy(timeout):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        if health() == "healthy":
            return round(time.monotonic() - t0, 2)
        time.sleep(0.5)
    return None


def scenario_launch(args):
    for i in range(args.iterations):
        if not quit_app():
            raise SystemExit("the app did not quit cleanly; not measuring a dirty start")
        time.sleep(args.settle)
        before = procs()
        off = log_offset(APP_LOG)
        t0 = time.monotonic()
        sh("open", "-a", "Sevoflurane")
        healthy_after = wait_healthy(args.timeout)
        wall = round(time.monotonic() - t0, 2)
        after = procs()
        cpu_s = {}
        for pid, (name, cput, _) in after.items():
            cpu_s[name] = round(cpu_s.get(name, 0.0) + cput - before.get(pid, (name, 0.0, 0.0))[1], 2)
        rec = {
            "scenario": "launch", "label": args.label, "t": now_iso(), "iteration": i + 1,
            "host": host(), "healthy_after_s": healthy_after, "wall_s": wall,
            "milestones": app_milestones(log_since(APP_LOG, off)),
            "cpu_s_to_healthy": {k: v for k, v in sorted(cpu_s.items()) if v > 0.05},
            "processes_at_healthy": len(after),
        }
        emit(rec, args)
        time.sleep(args.settle)


def scenario_idle(args):
    if health() != "healthy":
        raise SystemExit(f"app is {health()}, not healthy; idle needs a quiet healthy app")
    if control("/game/window").get("present"):
        raise SystemExit("a game window is up; idle needs no game running")
    for i in range(args.iterations):
        rec = {"scenario": "idle", "label": args.label, "t": now_iso(), "iteration": i + 1, "host": host()}
        rec["window"] = sample_window(args.seconds)
        emit(rec, args)


def scenario_game(args):
    if health() != "healthy":
        raise SystemExit(f"app is {health()}, not healthy")
    for i in range(args.iterations):
        if control("/game/window").get("present"):
            raise SystemExit("a game window is already up")
        woff = log_offset(WINE_LOG)
        aoff = log_offset(APP_LOG)
        t0 = time.monotonic()
        launch = sh(SEVO, "app", "launch", str(args.appid), "--json", "--timeout", str(args.timeout), timeout=args.timeout + 30)
        try:
            observed = json.loads(launch)
        except json.JSONDecodeError:
            observed = {"raw": launch.strip()[-300:]}
        window_after = round(time.monotonic() - t0, 2)
        rec = {
            "scenario": "game", "label": args.label, "t": now_iso(), "iteration": i + 1,
            "appid": args.appid, "host": host(), "window_after_s": window_after, "launch": observed,
        }
        time.sleep(args.warmup)
        rec["window"] = sample_window(args.seconds)
        sh(SEVO, "app", "terminate", str(args.appid), timeout=60)
        # the exit line lands when the process is gone
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not control("/game/window").get("present") is False:
            time.sleep(1)
        time.sleep(3)
        wine = log_since(WINE_LOG, woff)
        exe = observed.get("exe") or observed.get("process") or exe_from_log(wine, args.appid)
        rec["engine"] = gfx_lines(wine, exe) if exe else {}
        rec["exe"] = exe
        runs = sh(SEVO, "runs", "--last", "3", "--json", timeout=30)
        try:
            recs = [r for r in json.loads(runs) if r.get("appid") == args.appid]
            rec["run_record"] = recs[-1] if recs else None
        except json.JSONDecodeError:
            rec["run_record"] = None
        if "presents" in rec["engine"] and rec["run_record"]:
            dur = rec["run_record"].get("duration_s") or 0
            if dur:
                rec["engine"]["presents_per_s_whole_run"] = round(rec["engine"]["presents"] / dur, 1)
        emit(rec, args)
        time.sleep(args.settle)


def exe_from_log(wine, appid):
    m = re.findall(r"sevo:run pid=\d+ exe=(.+?) appid=%d " % appid, wine)
    return m[-1] if m else None


def emit(rec, args):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{rec['scenario']}.jsonl"
    with open(path, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(json.dumps(summary(rec), ensure_ascii=False))


def summary(rec):
    s = {"scenario": rec["scenario"], "label": rec["label"], "iteration": rec["iteration"]}
    if rec["scenario"] == "launch":
        s.update(healthy_after_s=rec["healthy_after_s"], milestones=rec["milestones"], cpu_s=rec["cpu_s_to_healthy"])
    elif rec["scenario"] == "idle":
        w = rec["window"]
        s.update(cpu_pct=w["cpu_pct"], cpu_total=w["cpu_pct_total"], rss_total_mb=w["rss_peak_total_mb"], gpu=w["gpu_pct_mean"])
    else:
        w = rec["window"]
        e = rec["engine"]
        s.update(appid=rec["appid"], window_after_s=rec["window_after_s"],
                 first_present_ms=e.get("first_present_ms"), executed_per_s=e.get("executed_per_s_last_interval"),
                 presents_per_s=e.get("presents_per_s_whole_run"), cpu_total=w["cpu_pct_total"], gpu=w["gpu_pct_mean"],
                 rss_total_mb=w["rss_peak_total_mb"])
    return s


# ---------------------------------------------------------------- report

def flatten(d, prefix=""):
    out = {}
    for k, v in d.items():
        key = f"{prefix}{k}"
        if isinstance(v, dict):
            out.update(flatten(v, key + "."))
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            out[key] = v
    return out


def scenario_report(args):
    rows = []
    for name in args.scenarios or ["launch", "idle", "game"]:
        path = OUT_DIR / f"{name}.jsonl"
        if not path.exists():
            continue
        for line in open(path):
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    if args.labels:
        rows = [r for r in rows if r["label"] in args.labels]
    by = {}
    for r in rows:
        key = (r["scenario"], r.get("appid"), r["label"])
        by.setdefault(key, []).append(flatten({k: v for k, v in r.items() if k not in ("host", "launch", "run_record")}))
    keys = sorted(by)
    metrics = ["healthy_after_s", "milestones.client_back", "milestones.healthy", "milestones.boot_audit_s",
               "cpu_s_to_healthy.app", "cpu_s_to_healthy.daemon",
               "window.cpu_pct_total", "window.cpu_pct.app", "window.cpu_pct.daemon", "window.cpu_pct.webhelper",
               "window.cpu_pct.steam", "window.cpu_pct.wine", "window.cpu_pct.wineserver", "window.rss_peak_total_mb",
               "window.gpu_pct_mean", "window_after_s", "engine.first_present_ms",
               "engine.executed_per_s_last_interval", "engine.presents_per_s_whole_run"]
    for key in keys:
        runs = by[key]
        print(f"\n== {key[0]}" + (f" appid={key[1]}" if key[1] else "") + f"  label={key[2]}  n={len(runs)}")
        for m in metrics:
            vals = [r[m] for r in runs if m in r and r[m] is not None]
            if not vals:
                continue
            med = statistics.median(vals)
            spread = f"  min {min(vals):g}  max {max(vals):g}" if len(vals) > 1 else ""
            print(f"  {m:<40} median {med:g}{spread}")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--label", default="baseline", help="name this build/config; report groups by it")
    ap.add_argument("--iterations", type=int, default=1)
    ap.add_argument("--settle", type=float, default=5.0, help="seconds to wait between runs")
    sub = ap.add_subparsers(dest="scenario", required=True)
    l = sub.add_parser("launch", help="cold app start to healthy")
    l.add_argument("--timeout", type=int, default=240)
    i = sub.add_parser("idle", help="per-process CPU and memory with nothing running")
    i.add_argument("--seconds", type=int, default=60)
    g = sub.add_parser("game", help="one game under the engine")
    g.add_argument("appid", type=int)
    g.add_argument("--seconds", type=int, default=60, help="steady-state sampling window")
    g.add_argument("--warmup", type=int, default=20, help="seconds after the window appears before sampling")
    g.add_argument("--timeout", type=int, default=180)
    r = sub.add_parser("report", help="medians per label from the recorded runs")
    r.add_argument("--labels", nargs="*")
    r.add_argument("--scenarios", nargs="*")
    args = ap.parse_args()
    {"launch": scenario_launch, "idle": scenario_idle, "game": scenario_game, "report": scenario_report}[args.scenario](args)


if __name__ == "__main__":
    main()
