#!/usr/bin/env python3
"""Aggregate an xctrace `thread-state` XML export per process and per thread.

Streams the file (it can be ~1 GB) and resolves xctrace's id/ref dedup.
Outputs: per-process running time, running-interval count (≈ wakeups),
blocked/preempted/runnable time; top threads by running time and by wakeups.
"""
import sys, collections, xml.etree.ElementTree as ET

path = sys.argv[1]
top_n = int(sys.argv[2]) if len(sys.argv) > 2 else 25

cache = {}          # id -> (tag, fmt)
cols = None
proc_stats = collections.defaultdict(lambda: collections.Counter())
thr_stats = collections.defaultdict(lambda: collections.Counter())
thr_proc = {}
trace_end = 0
rows = 0

def resolve(el):
    """Return (tag, fmt) for an element, following ref=."""
    if el.tag == "sentinel":
        return None
    ref = el.get("ref")
    if ref is not None:
        return cache.get(ref)
    fmt = el.get("fmt")
    val = (el.tag, fmt if fmt is not None else (el.text or ""))
    i = el.get("id")
    if i is not None:
        cache[i] = val
    return val

def raw(el):
    ref = el.get("ref")
    if ref is not None:
        return cache_raw.get(ref)
    v = el.text
    i = el.get("id")
    if i is not None:
        cache_raw[i] = v
    return v

cache_raw = {}

for event, el in ET.iterparse(path, events=("end",)):
    if el.tag == "schema":
        cols = [c.find("mnemonic").text for c in el.findall("col")]
        el.clear(); continue
    if el.tag != "row":
        continue
    rows += 1
    kids = list(el)
    rec = {}
    for name, kid in zip(cols, kids):
        if kid.tag == "sentinel":
            rec[name] = None; continue
        # numeric columns keep raw text; others keep fmt
        if name in ("start", "duration", "cputime", "waittime"):
            ref = kid.get("ref")
            if ref is not None:
                rec[name] = cache_raw.get(ref)
            else:
                rec[name] = kid.text
                i = kid.get("id")
                if i is not None:
                    cache_raw[i] = kid.text
            # also register fmt for completeness
            i = kid.get("id")
            if i is not None:
                cache[i] = (kid.tag, kid.get("fmt"))
        else:
            r = resolve(kid)
            rec[name] = r[1] if r else None
            # nested thread contains process/tid with ids too: register them
            for sub in kid.iter():
                if sub is kid: continue
                i = sub.get("id")
                if i is not None:
                    cache[i] = (sub.tag, sub.get("fmt") if sub.get("fmt") is not None else (sub.text or ""))
                    cache_raw[i] = sub.text
    el.clear()
    start = int(rec.get("start") or 0)
    dur = int(rec.get("duration") or 0)
    trace_end = max(trace_end, start + dur)
    state = rec.get("state") or "?"
    proc = rec.get("process") or "(no process)"
    thr = rec.get("thread") or "(no thread)"
    thr_proc[thr] = proc
    ps = proc_stats[proc]; ts = thr_stats[thr]
    ps[state + "_ns"] += dur; ts[state + "_ns"] += dur
    ps[state + "_n"] += 1; ts[state + "_n"] += 1

secs = trace_end / 1e9
print(f"rows={rows} trace_span={secs:.2f}s procs={len(proc_stats)} threads={len(thr_stats)}\n")

def fmt_ms(ns): return f"{ns/1e6:9.1f}"

print("== processes by Running time (ms over span; runs = Running intervals ≈ on-core episodes) ==")
print(f"{'process':52} {'run_ms':>9} {'%cpu':>6} {'runs':>8} {'runs/s':>8} {'preempt':>8} {'runnable_ms':>11}")
for proc, c in sorted(proc_stats.items(), key=lambda kv: -kv[1]["Running_ns"])[:top_n]:
    run = c["Running_ns"]
    print(f"{proc[:52]:52} {fmt_ms(run)} {100*run/1e9/secs:6.1f} {c['Running_n']:8d} {c['Running_n']/secs:8.0f} {c['Preempted_n']:8d} {fmt_ms(c['Runnable_ns'])}")

print("\n== processes by Running interval count (wakeup-ish) ==")
for proc, c in sorted(proc_stats.items(), key=lambda kv: -kv[1]["Running_n"])[:top_n]:
    print(f"{proc[:52]:52} runs={c['Running_n']:8d} ({c['Running_n']/secs:6.0f}/s) run_ms={c['Running_ns']/1e6:8.1f}")

print("\n== threads by Running time ==")
for thr, c in sorted(thr_stats.items(), key=lambda kv: -kv[1]["Running_ns"])[:top_n]:
    print(f"{thr[:90]:90} run_ms={c['Running_ns']/1e6:8.1f} runs={c['Running_n']:7d} runnable_ms={c['Runnable_ns']/1e6:7.1f}")

print("\n== threads by Running interval count ==")
for thr, c in sorted(thr_stats.items(), key=lambda kv: -kv[1]["Running_n"])[:top_n]:
    print(f"{thr[:90]:90} runs={c['Running_n']:7d} ({c['Running_n']/secs:6.0f}/s) run_ms={c['Running_ns']/1e6:8.1f}")

focus = [p for p in proc_stats if any(k in p for k in ("Sevoflurane", "WebKit", "steam", "Steam", "wine", "WindowServer"))]
print("\n== per-thread detail for Sevoflurane / WebKit / Steam / Wine / WindowServer ==")
for proc in sorted(focus, key=lambda p: -proc_stats[p]["Running_ns"]):
    c = proc_stats[proc]
    print(f"\n-- {proc}: run_ms={c['Running_ns']/1e6:.1f} runs={c['Running_n']} --")
    ths = [(t, s) for t, s in thr_stats.items() if thr_proc[t] == proc]
    for t, s in sorted(ths, key=lambda kv: -kv[1]["Running_ns"])[:12]:
        print(f"   {t[:80]:80} run_ms={s['Running_ns']/1e6:7.1f} runs={s['Running_n']:6d} ({s['Running_n']/secs:5.0f}/s)")
