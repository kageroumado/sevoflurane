import Foundation

/// The comparison of runs as data, as text, and as one self-contained HTML page.
nonisolated enum PerfReport {
    // MARK: - The model

    /// Everything the page draws, as JSON-ready values. Groups in order; the first is the
    /// baseline the others are measured against.
    static func model(_ groups: [PerfComparison.Group]) -> [String: Any] {
        let baseline = groups.first
        return [
            "groups": groups.enumerated().map { index, group in
                var entry: [String: Any] = [
                    "name": group.name,
                    "runs": group.runs.map(runModel),
                    "summary": groupSummary(group),
                ]
                if let baseline, index > 0 {
                    let versus = PerfComparison.versus(group, baseline: baseline)
                    entry["versus"] = [
                        "average": versus.average.map(differenceModel) as Any,
                        "low1": versus.low1.map(differenceModel) as Any,
                    ]
                }
                return entry
            },
        ]
    }

    private static func runModel(_ run: PerfComparison.Run) -> [String: Any] {
        let summary = run.summary
        var model: [String: Any] = [
            "t": run.record.t,
            "moment": PerfRuns.moment(run.record.t),
            "game": run.record.name ?? "app \(run.record.appid)",
            "trace": run.trace,
            "dropped": run.dropped,
            "config": Dictionary(uniqueKeysWithValues: PerfComparison.configuration(of: run).map { ($0.field, $0.value) }),
            "frameTime": frameTimeSeries(run.frameTimes),
            "fps": perSecondSeries(run.frameTimes),
            "percentiles": percentileCurve(run.frameTimes),
        ]
        if let label = run.label { model["label"] = label }
        if let summary { model["summary"] = summaryModel(summary) }
        return model
    }

    private static func summaryModel(_ summary: FrameStats.Summary) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(summary),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func differenceModel(_ difference: FrameStats.Difference) -> [String: Any] {
        var model: [String: Any] = [
            "base": difference.base, "delta": difference.delta, "percent": difference.percent,
            "low": difference.low, "high": difference.high,
            "percentLow": difference.percentLow, "percentHigh": difference.percentHigh,
            "method": difference.method.rawValue, "significant": difference.isSignificant,
        ]
        if let p = difference.p { model["p"] = p }
        return model
    }

    /// The group's runs together: the mean and spread of their averages and 1 % lows.
    private static func groupSummary(_ group: PerfComparison.Group) -> [String: Any] {
        let summaries = group.runs.compactMap(\.summary)
        func spread(_ values: [Double]) -> [String: Double] {
            let mean = values.reduce(0, +) / Double(max(1, values.count))
            let sd = values.count > 1
                ? (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)).squareRoot()
                : 0
            return ["mean": mean, "sd": sd]
        }
        return [
            "runs": summaries.count,
            "avg": spread(summaries.map(\.avg)),
            "low1": spread(summaries.map(\.low1)),
            "p99": spread(summaries.map(\.p99)),
            "hitchesPerMinute": spread(summaries.map { $0.seconds > 0 ? Double($0.hitches) * 60 / $0.seconds : 0 }),
        ]
    }

    /// At most this many points per line: about one per pixel of the plot.
    static let seriesPoints = 900

    /// Frame time over the run, bucketed: each point is a bucket's end time, its mean frame
    /// time and its slowest frame, so a hitch survives the thinning.
    static func frameTimeSeries(_ times: [Float]) -> [[Double]] {
        let bucket = max(1, Int((Double(times.count) / Double(seriesPoints)).rounded(.up)))
        var points: [[Double]] = []
        var clock = 0.0
        var index = 0
        while index < times.count {
            let slice = times[index ..< min(times.count, index + bucket)]
            let sum = slice.reduce(0.0) { $0 + Double($1) }
            clock += sum / 1000
            points.append([round3(clock), round3(sum / Double(slice.count)), round3(Double(slice.max() ?? 0))])
            index += bucket
        }
        return points
    }

    /// Frames per second in each second, thinned to ``seriesPoints`` by averaging.
    static func perSecondSeries(_ times: [Float]) -> [[Double]] {
        let rates = FrameStats.perSecond(times)
        let bucket = max(1, Int((Double(rates.count) / Double(seriesPoints)).rounded(.up)))
        return stride(from: 0, to: rates.count, by: bucket).map { start in
            let slice = rates[start ..< min(rates.count, start + bucket)]
            return [Double(start + slice.count), round3(slice.reduce(0, +) / Double(slice.count))]
        }
    }

    /// The frame time at each percentile, from the median to the slowest frame worth naming:
    /// how far a run's tail stretches.
    static let percentiles: [Double] = [50, 60, 70, 80, 85, 90, 93, 95, 97, 98, 99, 99.5, 99.7, 99.8, 99.9, 99.95, 99.99]

    static func percentileCurve(_ times: [Float]) -> [[Double]] {
        let sorted = times.sorted()
        return percentiles.filter { (100 - $0) / 100 * Double(sorted.count) >= 1 }.map {
            [$0, round3(FrameStats.percentile(sorted, $0 / 100))]
        }
    }

    private static func round3(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    // MARK: - Text

    static func textLines(_ groups: [PerfComparison.Group]) -> [String] {
        guard let baseline = groups.first else { return [] }
        var lines: [String] = []
        for (index, group) in groups.enumerated() {
            let summaries = group.runs.compactMap(\.summary)
            let avg = summaries.map(\.avg), low = summaries.map(\.low1)
            lines.append("\(index == 0 ? "baseline" : "vs baseline") · \(group.name) · \(group.runs.count) run\(group.runs.count == 1 ? "" : "s")")
            lines.append("    average \(describe(avg)) fps · 1 % low \(describe(low)) fps · p99 \(describe(summaries.map(\.p99))) ms")
            if index > 0 {
                let versus = PerfComparison.versus(group, baseline: baseline)
                lines.append("    average: \(verdict(versus.average))")
                lines.append("    1 % low: \(verdict(versus.low1))")
            }
        }
        return lines
    }

    private static func describe(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "–" }
        let mean = values.reduce(0, +) / Double(values.count)
        guard values.count > 1 else { return String(format: "%.1f", mean) }
        let sd = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)).squareRoot()
        return String(format: "%.1f ± %.1f", mean, sd)
    }

    /// "+12.3 % (95 % CI +8.1 to +16.4 %, Welch p 0.003) — higher".
    static func verdict(_ difference: FrameStats.Difference?) -> String {
        guard let difference else { return "not enough frames or runs to compare" }
        let interval = String(
            format: "95 %% CI %+.1f to %+.1f %%", difference.percentLow, difference.percentHigh,
        )
        let method = difference.method == .welch
            ? "Welch" + (difference.p.map { String(format: " p %.3g", $0) } ?? "")
            : "block bootstrap over frames, fewer than two runs on a side"
        let word = !difference.isSignificant ? "no measurable difference"
            : difference.delta > 0 ? "higher" : "lower"
        return String(format: "%+.1f %% (", difference.percent) + interval + ", \(method)) — \(word)"
    }

    // MARK: - The page

    static func html(runs: [PerfComparison.Run], skip: Double, duration: Double?) -> String {
        let groups = PerfComparison.groups(runs)
        var page = model(groups)
        let games = Set(runs.map { $0.record.name ?? "app \($0.record.appid)" }).sorted()
        page["title"] = games.joined(separator: ", ")
        var window = skip > 0 ? "first \(Int(skip)) s left out" : "whole runs"
        if let duration { window += ", \(Int(duration)) s kept" }
        page["window"] = window
        page["generated"] = PerfRuns.moment(runRecordStamp.string(from: .now))
        let json = (try? JSONSerialization.data(withJSONObject: page, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // `</` would end the script element early.
        let safe = json.replacingOccurrences(of: "</", with: "<\\/")
        return template.replacingOccurrences(of: "/*DATA*/null", with: safe)
    }

    private static let template = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Frame Times</title>
    <style>
    :root {
      color-scheme: light;
      --page: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
      --grid: #e1e0d9; --axis: #c3c2b7; --border: rgba(11,11,11,0.10);
      --good: #006300; --bad: #d03b3b;
      --s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a; --s4: #eda100;
      --s5: #e87ba4; --s6: #008300; --s7: #4a3aa7; --s8: #e34948;
    }
    @media (prefers-color-scheme: dark) {
      :root:where(:not([data-theme="light"])) {
        color-scheme: dark;
        --page: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
        --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10);
        --good: #0ca30c; --bad: #e66767;
        --s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #c98500;
        --s5: #d55181; --s6: #008300; --s7: #9085e9; --s8: #e66767;
      }
    }
    :root[data-theme="dark"] {
      color-scheme: dark;
      --page: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
      --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10);
      --good: #0ca30c; --bad: #e66767;
      --s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #c98500;
      --s5: #d55181; --s6: #008300; --s7: #9085e9; --s8: #e66767;
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--page); color: var(--ink);
      font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
    main { max-width: 1120px; margin: 0 auto; padding: 32px 16px 64px; }
    h1 { font-size: 22px; font-weight: 650; margin: 0 0 4px; }
    .sub { color: var(--ink-2); margin: 0 0 24px; }
    h2 { font-size: 15px; font-weight: 600; margin: 0 0 2px; }
    .note { color: var(--muted); font-size: 12px; margin: 0 0 12px; }
    section { background: var(--surface); border: 1px solid var(--border); border-radius: 12px;
      padding: 18px 18px 14px; margin: 0 0 16px; }
    table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
    th { text-align: right; font-weight: 500; color: var(--muted); font-size: 12px; padding: 6px 8px;
      border-bottom: 1px solid var(--grid); white-space: nowrap; }
    td { text-align: right; padding: 7px 8px; border-bottom: 1px solid var(--grid); white-space: nowrap; }
    th:first-child, td:first-child { text-align: left; white-space: normal; }
    tr:last-child td { border-bottom: none; }
    .swatch { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 8px;
      vertical-align: 0; }
    .up { color: var(--good); } .down { color: var(--bad); } .flat { color: var(--ink-2); }
    .detail { color: var(--muted); font-size: 12px; }
    .legend { display: flex; flex-wrap: wrap; gap: 6px 16px; margin: 0 0 10px; color: var(--ink-2);
      font-size: 12px; }
    .legend button { all: unset; cursor: pointer; display: inline-flex; align-items: center; }
    .legend button[aria-pressed="false"] { color: var(--muted); text-decoration: line-through; }
    .chart { position: relative; }
    svg { display: block; width: 100%; height: auto; overflow: visible; }
    .gridline { stroke: var(--grid); stroke-width: 1; }
    .axisline { stroke: var(--axis); stroke-width: 1; }
    .tick { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
    .axis-title { fill: var(--muted); font-size: 11px; }
    .line { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
    .band { stroke: none; opacity: 0.16; }
    .cross { stroke: var(--axis); stroke-width: 1; }
    .tip { position: absolute; pointer-events: none; background: var(--surface); color: var(--ink);
      border: 1px solid var(--border); border-radius: 8px; padding: 8px 10px; font-size: 12px;
      box-shadow: 0 4px 16px rgba(0,0,0,0.12); white-space: nowrap; display: none;
      font-variant-numeric: tabular-nums; }
    .tip b { font-weight: 600; }
    .tip .row { display: flex; align-items: center; gap: 6px; }
    .scroll { overflow-x: auto; }
    </style>
    </head>
    <body>
    <main>
      <h1 id="title"></h1>
      <p class="sub" id="sub"></p>

      <section>
        <h2>Configurations</h2>
        <p class="note" id="method"></p>
        <div class="scroll"><table id="groups"></table></div>
      </section>

      <section>
        <h2>Frame time</h2>
        <p class="note">The line is each moment's mean frame time; the band reaches its slowest frame (first run of each configuration). Lower is better.</p>
        <div class="legend" data-legend></div>
        <div class="chart" id="frametime"></div>
      </section>

      <section>
        <h2>Frame rate</h2>
        <p class="note">Frames in each second. Higher is better.</p>
        <div class="legend" data-legend></div>
        <div class="chart" id="fps"></div>
      </section>

      <section>
        <h2>Frame time by percentile</h2>
        <p class="note">How long the slowest frames take: at 99, one frame in a hundred is this slow or slower. A flat curve is a smooth run.</p>
        <div class="legend" data-legend></div>
        <div class="chart" id="percentiles"></div>
      </section>

      <section>
        <h2>Runs</h2>
        <div class="scroll"><table id="runs"></table></div>
      </section>
    </main>
    <script>
    const DATA = /*DATA*/null;
    const SLOTS = 8;
    const runs = [];
    DATA.groups.forEach((g, gi) => g.runs.forEach((r, ri) => runs.push({ ...r, group: gi, repeat: ri })));
    const color = gi => `var(--s${(gi % SLOTS) + 1})`;
    const dash = ri => ["", "6 4", "2 3", "10 4 2 4"][ri % 4];
    const hidden = new Set();
    const fmt = (v, d = 1) => v == null || isNaN(v) ? "–" : Number(v).toFixed(d);
    const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
    const runName = r => DATA.groups[r.group].name + (DATA.groups[r.group].runs.length > 1 ? ` · run ${r.repeat + 1}` : "");

    document.getElementById("title").textContent = DATA.title || "Frame times";
    document.getElementById("sub").textContent =
      `${runs.length} run${runs.length === 1 ? "" : "s"} in ${DATA.groups.length} configuration${DATA.groups.length === 1 ? "" : "s"} · ${DATA.window} · made ${DATA.generated}`;

    // --- Configurations table
    (function () {
      const withRepeats = DATA.groups.length > 1 && DATA.groups.every(g => g.runs.length >= 2);
      document.getElementById("method").textContent = DATA.groups.length < 2
        ? "One configuration: nothing to compare yet. Run the game again with a different setting."
        : withRepeats
          ? "Each configuration against the first. Intervals are 95 % from Welch's t-test over the runs."
          : "Each configuration against the first. With a single run on a side, intervals come from a block bootstrap over that run's seconds; repeat each configuration two or more times for a test over runs.";
      const head = "<tr><th>Configuration</th><th>Runs</th><th>Average fps</th><th>1 % low fps</th><th>p99 ms</th><th>Hitches / min</th><th>Average vs first</th><th>1 % low vs first</th></tr>";
      const spread = s => s.runs > 1 ? `${fmt(s.mean)} <span class="detail">± ${fmt(s.sd)}</span>` : fmt(s.mean);
      const diff = d => {
        if (!d) return '<span class="detail">–</span>';
        const cls = !d.significant ? "flat" : d.delta > 0 ? "up" : "down";
        const p = d.p != null ? ` · p ${d.p < 0.001 ? "< 0.001" : fmt(d.p, 3)}` : "";
        return `<span class="${cls}">${d.percent >= 0 ? "+" : ""}${fmt(d.percent)} %</span><br><span class="detail">${fmt(d.percentLow)} to ${fmt(d.percentHigh)} %${p}</span>`;
      };
      const rows = DATA.groups.map((g, gi) => {
        const s = g.summary;
        const v = g.versus || {};
        return `<tr><td><span class="swatch" style="background:${color(gi)}"></span>${esc(g.name)}</td>
          <td>${s.runs}</td><td>${spread({ ...s.avg, runs: s.runs })}</td><td>${spread({ ...s.low1, runs: s.runs })}</td>
          <td>${spread({ ...s.p99, runs: s.runs })}</td><td>${spread({ ...s.hitchesPerMinute, runs: s.runs })}</td>
          <td>${gi === 0 ? '<span class="detail">baseline</span>' : diff(v.average)}</td>
          <td>${gi === 0 ? '<span class="detail">baseline</span>' : diff(v.low1)}</td></tr>`;
      }).join("");
      document.getElementById("groups").innerHTML = head + rows;
    })();

    // --- Runs table
    (function () {
      const head = "<tr><th>Run</th><th>Started</th><th>Frames</th><th>Seconds</th><th>Average</th><th>1 %</th><th>0.1 %</th><th>p50 ms</th><th>p99 ms</th><th>Max ms</th><th>Hitches</th></tr>";
      const rows = runs.map(r => {
        const s = r.summary || {};
        const dropped = r.dropped ? ` <span class="detail">(${r.dropped} unread)</span>` : "";
        return `<tr><td><span class="swatch" style="background:${color(r.group)}"></span>${esc(runName(r))}</td>
          <td>${esc(r.moment)}</td><td>${s.frames ?? "–"}${dropped}</td><td>${fmt(s.seconds, 0)}</td><td>${fmt(s.avg)}</td>
          <td>${fmt(s.low1)}</td><td>${fmt(s.low01)}</td><td>${fmt(s.p50, 2)}</td><td>${fmt(s.p99, 2)}</td>
          <td>${fmt(s.max, 1)}</td><td>${s.hitches ?? "–"}</td></tr>`;
      }).join("");
      document.getElementById("runs").innerHTML = head + rows;
    })();

    // --- Charts
    const NS = "http://www.w3.org/2000/svg";
    const el = (name, attrs, parent) => {
      const node = document.createElementNS(NS, name);
      for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
      if (parent) parent.appendChild(node);
      return node;
    };
    function niceTicks(lo, hi, count) {
      const span = hi - lo || 1, raw = span / count, mag = Math.pow(10, Math.floor(Math.log10(raw)));
      const step = [1, 2, 2.5, 5, 10].map(m => m * mag).find(s => span / s <= count) || 10 * mag;
      const ticks = [];
      for (let v = Math.ceil(lo / step) * step; v <= hi + step * 1e-9; v += step) ticks.push(+v.toFixed(6));
      return ticks;
    }

    // spec: { id, series: run => [[x, y, yHigh?]], xLabel, yLabel, xTicks?, xFormat, yFormat, xMap? }
    const charts = [];
    function lineChart(spec) {
      const host = document.getElementById(spec.id);
      const W = 1060, H = 300, M = { l: 52, r: 16, t: 10, b: 38 };
      const tip = document.createElement("div"); tip.className = "tip"; host.appendChild(tip);
      function draw() {
        host.querySelector("svg")?.remove();
        const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": spec.yLabel }, null);
        host.insertBefore(svg, tip);
        const visible = runs.filter(r => !hidden.has(r.group));
        const xMap = spec.xMap || (v => v), xUnmap = spec.xUnmap || (v => v);
        let xs = [], ys = [];
        visible.forEach(r => spec.series(r).forEach(p => { xs.push(xMap(p[0])); ys.push(p[2] ?? p[1]); }));
        if (!xs.length) return;
        const x0 = Math.min(...xs), x1 = Math.max(...xs);
        ys.sort((a, b) => a - b);
        // The top of the plot is the 99.5th percentile of what is drawn, so one frozen frame
        // cannot flatten everything else; points above it are clipped at the edge.
        const yTop = Math.max(spec.yMin || 0, ys[Math.floor(ys.length * 0.995)] * 1.08 || 1);
        const sx = v => M.l + (xMap(v) - x0) / (x1 - x0 || 1) * (W - M.l - M.r);
        const sy = v => H - M.b - Math.min(v, yTop) / yTop * (H - M.t - M.b);
        niceTicks(0, yTop, 5).forEach(t => {
          el("line", { class: "gridline", x1: M.l, x2: W - M.r, y1: sy(t), y2: sy(t) }, svg);
          el("text", { class: "tick", x: M.l - 8, y: sy(t) + 4, "text-anchor": "end" }, svg).textContent = spec.yFormat(t);
        });
        el("line", { class: "axisline", x1: M.l, x2: W - M.r, y1: H - M.b, y2: H - M.b }, svg);
        (spec.xTicks ? spec.xTicks.filter(t => xMap(t) >= x0 && xMap(t) <= x1) : niceTicks(xUnmap(x0), xUnmap(x1), 8)).forEach(t => {
          el("text", { class: "tick", x: sx(t), y: H - M.b + 16, "text-anchor": "middle" }, svg).textContent = spec.xFormat(t);
        });
        el("text", { class: "axis-title", x: W - M.r, y: H - 4, "text-anchor": "end" }, svg).textContent = spec.xLabel;
        el("text", { class: "axis-title", x: M.l, y: M.t - 0, "text-anchor": "start", dy: "-2" }, svg).textContent = spec.yLabel;
        visible.forEach(r => {
          const pts = spec.series(r);
          if (!pts.length) return;
          // One band per configuration: the repeats' bands would stack into noise.
          if (pts[0].length > 2 && r.repeat === 0) {
            const top = pts.map(p => `${sx(p[0]).toFixed(1)},${sy(p[2]).toFixed(1)}`).join(" ");
            const bottom = pts.slice().reverse().map(p => `${sx(p[0]).toFixed(1)},${sy(p[1]).toFixed(1)}`).join(" ");
            el("polygon", { class: "band", points: `${top} ${bottom}`, style: `fill:${color(r.group)}` }, svg);
          }
          el("polyline", {
            class: "line", points: pts.map(p => `${sx(p[0]).toFixed(1)},${sy(p[1]).toFixed(1)}`).join(" "),
            style: `stroke:${color(r.group)}`, "stroke-dasharray": dash(r.repeat),
          }, svg);
        });
        const cross = el("line", { class: "cross", y1: M.t, y2: H - M.b, visibility: "hidden" }, svg);
        const hit = el("rect", { x: M.l, y: M.t, width: W - M.l - M.r, height: H - M.t - M.b, fill: "transparent" }, svg);
        hit.addEventListener("mousemove", ev => {
          const box = svg.getBoundingClientRect(), scale = W / box.width;
          const px = (ev.clientX - box.left) * scale;
          const xv = xUnmap(x0 + (px - M.l) / (W - M.l - M.r) * (x1 - x0));
          cross.setAttribute("x1", px); cross.setAttribute("x2", px); cross.setAttribute("visibility", "visible");
          const rows = visible.map(r => {
            const pts = spec.series(r);
            let best = null, bestD = Infinity;
            for (const p of pts) { const d = Math.abs(xMap(p[0]) - xMap(xv)); if (d < bestD) { bestD = d; best = p; } }
            return best ? `<div class="row"><span class="swatch" style="background:${color(r.group)}"></span>${esc(runName(r))}: <b>${spec.yFormat(best[1], true)}</b>${best.length > 2 ? ` <span class="detail">slowest ${spec.yFormat(best[2], true)}</span>` : ""}</div>` : "";
          }).join("");
          tip.innerHTML = `<div class="detail">${spec.xFormat(xv, true)}</div>${rows}`;
          tip.style.display = "block";
          const left = (ev.clientX - host.getBoundingClientRect().left) + 14;
          tip.style.left = `${Math.min(left, host.clientWidth - tip.offsetWidth - 4)}px`;
          tip.style.top = `${(ev.clientY - host.getBoundingClientRect().top) + 14}px`;
        });
        hit.addEventListener("mouseleave", () => { tip.style.display = "none"; cross.setAttribute("visibility", "hidden"); });
      }
      charts.push(draw);
      draw();
    }

    lineChart({
      id: "frametime", series: r => r.frameTime, xLabel: "seconds", yLabel: "ms", yMin: 20,
      xFormat: (v, long) => long ? `${fmt(v, 1)} s` : `${Math.round(v)}`, yFormat: (v, long) => long ? `${fmt(v, 2)} ms` : `${Math.round(v)}`,
    });
    lineChart({
      id: "fps", series: r => r.fps, xLabel: "seconds", yLabel: "fps",
      xFormat: (v, long) => long ? `${Math.round(v)} s` : `${Math.round(v)}`, yFormat: (v, long) => long ? `${fmt(v, 1)} fps` : `${Math.round(v)}`,
    });
    // Percentiles on a scale that spreads the tail: x is −log10(100 − p).
    lineChart({
      id: "percentiles", series: r => r.percentiles, xLabel: "percentile", yLabel: "ms", yMin: 20,
      xMap: p => -Math.log10(100 - p), xUnmap: v => 100 - Math.pow(10, -v),
      xTicks: [50, 90, 99, 99.9, 99.99],
      xFormat: (v, long) => long ? `${fmt(v, 2)}th percentile` : `${v}`, yFormat: (v, long) => long ? `${fmt(v, 2)} ms` : `${Math.round(v)}`,
    });

    // --- Legends: one per chart, toggling a configuration everywhere
    function legends() {
      document.querySelectorAll("[data-legend]").forEach(box => {
        box.innerHTML = DATA.groups.map((g, gi) =>
          `<button type="button" data-group="${gi}" aria-pressed="${!hidden.has(gi)}"><span class="swatch" style="background:${color(gi)}"></span>${esc(g.name)}</button>`).join("");
      });
      document.querySelectorAll("[data-group]").forEach(b => b.addEventListener("click", () => {
        const gi = +b.dataset.group;
        if (hidden.has(gi)) hidden.delete(gi); else if (hidden.size < DATA.groups.length - 1) hidden.add(gi);
        legends(); charts.forEach(draw => draw());
      }));
    }
    legends();
    </script>
    </body>
    </html>
    """#
}
