#!/usr/bin/env python3
"""Aggregate an xctrace `time-profile` XML export: samples per process, per
thread, and the hottest leaf / hottest non-system frames per process."""
import sys, collections, re, xml.etree.ElementTree as ET

path = sys.argv[1]
focus_re = re.compile(sys.argv[2]) if len(sys.argv) > 2 else re.compile(r"Sevoflurane|WebKit|steam|Steam|wine|WindowServer")
top_n = 18

cache = {}            # id -> resolved value (string for scalars, list-of-frames for backtraces)
cols = None
proc_w = collections.Counter()
thr_w = collections.Counter()
thr_proc = {}
leaf_by_proc = collections.defaultdict(collections.Counter)
user_by_proc = collections.defaultdict(collections.Counter)
anyframe_by_proc = collections.defaultdict(collections.Counter)
rows = 0
total_w = 0

SYSTEM_BIN = re.compile(r"^(libsystem|libdispatch|libobjc|dyld|libc\+\+|libpthread|kernel|libxpc|CoreFoundation|Foundation|libswift|libdyld)")

def frames_of(bt):
    out = []
    for fr in bt.iter("frame"):
        b = fr.find("binary")
        out.append((fr.get("name") or "?", b.get("name") if b is not None else "?"))
    return out

def resolve(el):
    if el.tag == "sentinel":
        return None
    ref = el.get("ref")
    if ref is not None:
        return cache.get(ref)
    if el.tag in ("backtrace", "text-backtrace", "tagged-backtrace"):
        bt = el if el.tag == "backtrace" else (el.find("backtrace") if el.find("backtrace") is not None else el)
        val = frames_of(bt)
    else:
        val = el.get("fmt") if el.get("fmt") is not None else (el.text or "")
    i = el.get("id")
    if i is not None:
        cache[i] = val
    # register nested ids (thread contains process, backtrace contains frames)
    for sub in el.iter():
        if sub is el: continue
        si = sub.get("id")
        if si is not None and si not in cache:
            if sub.tag == "backtrace":
                cache[si] = frames_of(sub)
            else:
                cache[si] = sub.get("fmt") if sub.get("fmt") is not None else (sub.text or "")
    return val

for event, el in ET.iterparse(path, events=("end",)):
    if el.tag == "schema":
        cols = [c.find("mnemonic").text for c in el.findall("col")]
        print("columns:", cols, file=sys.stderr)
        el.clear(); continue
    if el.tag != "row":
        continue
    rows += 1
    rec = {}
    for name, kid in zip(cols, list(el)):
        rec[name] = resolve(kid)
    el.clear()
    w = rec.get("weight")
    try:
        w = int(w) if w is not None else 1
    except ValueError:
        w = 1
    proc = rec.get("process") or "?"
    thr = rec.get("thread") or "?"
    total_w += w
    proc_w[proc] += w
    thr_w[thr] += w
    thr_proc[thr] = proc
    bt = rec.get("stack") or rec.get("backtrace")
    if isinstance(bt, list) and bt and focus_re.search(proc):
        leaf_by_proc[proc][f"{bt[0][0]}  ({bt[0][1]})"] += w
        seen = set()
        for name, binname in bt:
            key = f"{name}  ({binname})"
            if key in seen: continue
            seen.add(key)
            anyframe_by_proc[proc][key] += w
        for name, binname in bt:
            if not SYSTEM_BIN.match(binname or ""):
                user_by_proc[proc][f"{name}  ({binname})"] += w
                break

unit = "ns" if total_w > 10_000_000 else "samples"
def fmt(w): return f"{w/1e6:9.1f}ms" if unit == "ns" else f"{w:8d}"
print(f"rows={rows} total_weight={total_w} ({unit})\n")
print("== processes by sampled CPU ==")
for p, w in proc_w.most_common(35):
    print(f"{p[:56]:56} {fmt(w)} {100*w/total_w:6.1f}%")
print("\n== focus processes: threads and hottest frames ==")
for p, w in proc_w.most_common():
    if not focus_re.search(p): continue
    print(f"\n-- {p}: {fmt(w)} ({100*w/total_w:.1f}% of all samples) --")
    ths = [(t, tw) for t, tw in thr_w.items() if thr_proc[t] == p]
    for t, tw in sorted(ths, key=lambda kv: -kv[1])[:8]:
        print(f"   thread {t[:70]:70} {fmt(tw)}")
    print("   leaf frames:")
    for k, kw in leaf_by_proc[p].most_common(10):
        print(f"      {fmt(kw)}  {k[:110]}")
    print("   first non-system frame:")
    for k, kw in user_by_proc[p].most_common(top_n):
        print(f"      {fmt(kw)}  {k[:120]}")
    print("   inclusive (any frame) — app/WebKit symbols:")
    shown = 0
    for k, kw in anyframe_by_proc[p].most_common(400):
        if SYSTEM_BIN.match(k.split("(")[-1]): continue
        if k.startswith(("0x", "start", "thread_start", "_pthread")): continue
        print(f"      {fmt(kw)}  {k[:120]}")
        shown += 1
        if shown >= 25: break
