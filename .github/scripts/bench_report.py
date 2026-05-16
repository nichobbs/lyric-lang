#!/usr/bin/env python3
"""Generate a self-contained HTML performance report from `lyric bench` output.

Usage:
    python bench_report.py --output report.html [--title "My Run"] result1.txt ...

Each positional argument is a file containing the stdout of one
`lyric bench <file.l>` invocation.  The file name (minus extension) is used
as the suite label.  Non-matching lines (e.g. interleaved stderr via tee) are
silently skipped.

Note: the generated HTML loads Chart.js from the jsdelivr CDN at view-time.
Rendering the charts requires outbound internet access.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from html import escape

# ─── Parsing ──────────────────────────────────────────────────────────────────

def parse_result(path):
    """Return (suite_label, runs, warmup, benchmarks) from a lyric bench output file."""
    label = re.sub(r'^bench_?', '', os.path.splitext(os.path.basename(path))[0])
    label = label.replace('_', ' ').title()
    runs = warmup = None
    benches = []
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if line.startswith('benchmark'):
                m = re.search(r'runs=(\d+)', line)
                if m:
                    runs = int(m.group(1))
                m = re.search(r'warmup=(\d+)', line)
                if m:
                    warmup = int(m.group(1))
            elif line and 'min=' in line:
                m = re.match(
                    r'^(\S+)\s+min=([\d.]+)ms\s+max=([\d.]+)ms\s+mean=([\d.]+)ms',
                    line,
                )
                if m:
                    benches.append({
                        'name':  m.group(1),
                        'min':   float(m.group(2)),
                        'max':   float(m.group(3)),
                        'mean':  float(m.group(4)),
                    })
    if runs is None:
        print(f'warning: {path}: missing "benchmark runs=N" header; run/warmup counts unknown',
              file=sys.stderr)
    if warmup is None and runs is not None:
        print(f'warning: {path}: missing warmup count in header', file=sys.stderr)
    return label, runs, warmup, benches

# ─── HTML generation ──────────────────────────────────────────────────────────

# Chart.js is fetched from jsdelivr at view-time so the artifact stays small.
# The rendered HTML requires outbound internet access to display the charts.
CHARTJS_CDN = 'https://cdn.jsdelivr.net/npm/chart.js@4.4.4/dist/chart.umd.min.js'

CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: #f5f7fa;
    color: #1a1a2e;
    padding: 2rem;
}
h1 { font-size: 1.6rem; font-weight: 700; margin-bottom: 0.25rem; }
.meta { color: #666; font-size: 0.85rem; margin-bottom: 2rem; }
.meta span { margin-right: 1.5rem; }
.suite { background: #fff; border-radius: 10px; box-shadow: 0 1px 4px #0001;
         padding: 1.5rem; margin-bottom: 2rem; }
.suite h2 { font-size: 1.1rem; font-weight: 600; margin-bottom: 1rem;
            border-bottom: 2px solid #e8eaf0; padding-bottom: 0.5rem; }
.suite-body { display: flex; gap: 2rem; align-items: flex-start; flex-wrap: wrap; }
.chart-wrap { flex: 1 1 400px; min-height: 200px; max-height: 320px; position: relative; }
table { border-collapse: collapse; font-size: 0.82rem; min-width: 300px; }
th { text-align: left; padding: 0.4rem 0.8rem; background: #f0f2f8;
     font-weight: 600; color: #444; border-bottom: 1px solid #dde; }
td { padding: 0.35rem 0.8rem; border-bottom: 1px solid #eef; }
tr:last-child td { border-bottom: none; }
td.num { text-align: right; font-variant-numeric: tabular-nums; }
td.name { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 0.78rem; }
.badge { display: inline-block; padding: 0.15rem 0.4rem; border-radius: 4px;
         font-size: 0.72rem; font-weight: 600; }
.badge-fast { background: #d4edda; color: #155724; }
.badge-slow { background: #f8d7da; color: #721c24; }
.summary-table th, .summary-table td { padding: 0.4rem 1rem; }
"""

def suite_chart_js(suite_id, benches):
    """Return a <script> block that draws the chart for one suite."""
    names  = [b['name'] for b in benches]
    mins   = [b['min']  for b in benches]
    maxs   = [b['max']  for b in benches]
    means  = [b['mean'] for b in benches]
    n = len(benches)

    datasets = json.dumps([
        {
            'label':           'min',
            'data':            mins,
            'backgroundColor': ['rgba(99,102,241,0.5)'] * n,
            'borderColor':     ['rgba(99,102,241,1)']   * n,
            'borderWidth':     1,
        },
        {
            'label':           'mean',
            'data':            means,
            'backgroundColor': ['rgba(14,165,233,0.75)'] * n,
            'borderColor':     ['rgba(14,165,233,1)']    * n,
            'borderWidth':     1,
        },
        {
            'label':           'max',
            'data':            maxs,
            'backgroundColor': ['rgba(239,68,68,0.35)'] * n,
            'borderColor':     ['rgba(239,68,68,1)']    * n,
            'borderWidth':     1,
        },
    ])
    labels = json.dumps(names)

    return f"""
<script>
(function(){{
  var ctx = document.getElementById('{suite_id}').getContext('2d');
  new Chart(ctx, {{
    type: 'bar',
    data: {{ labels: {labels}, datasets: {datasets} }},
    options: {{
      indexAxis: 'y',
      responsive: true,
      maintainAspectRatio: false,
      plugins: {{
        legend: {{ position: 'top', labels: {{ font: {{ size: 11 }} }} }},
        tooltip: {{
          callbacks: {{
            label: ctx => ctx.dataset.label + ': ' + ctx.parsed.x.toFixed(3) + ' ms'
          }}
        }}
      }},
      scales: {{
        x: {{
          title: {{ display: true, text: 'milliseconds', font: {{ size: 11 }} }},
          beginAtZero: true,
          ticks: {{ font: {{ size: 10 }} }}
        }},
        y: {{
          ticks: {{ font: {{ family: 'monospace', size: 10 }} }}
        }}
      }}
    }}
  }});
}})();
</script>"""

def suite_table(benches):
    """Return the HTML for the data table of one suite."""
    fastest = min(b['mean'] for b in benches)
    slowest = max(b['mean'] for b in benches)
    rows = []
    for b in benches:
        badge = ''
        if len(benches) > 1 and fastest != slowest:
            if b['mean'] == fastest:
                badge = ' <span class="badge badge-fast">fastest</span>'
            elif b['mean'] == slowest:
                badge = ' <span class="badge badge-slow">slowest</span>'
        rows.append(
            f'<tr>'
            f'<td class="name">{escape(b["name"])}{badge}</td>'
            f'<td class="num">{b["min"]:.3f}</td>'
            f'<td class="num">{b["mean"]:.3f}</td>'
            f'<td class="num">{b["max"]:.3f}</td>'
            f'<td class="num">{b["max"] - b["min"]:.3f}</td>'
            f'</tr>'
        )
    return (
        '<table>'
        '<thead><tr>'
        '<th>Benchmark</th><th>min (ms)</th><th>mean (ms)</th><th>max (ms)</th><th>spread</th>'
        '</tr></thead>'
        '<tbody>' + ''.join(rows) + '</tbody>'
        '</table>'
    )

def overall_summary_table(suites):
    """One-row-per-suite overview: suite name, bench count, fastest, slowest mean."""
    rows = []
    for label, _, _, benches in suites:
        if not benches:
            continue
        fastest = min(benches, key=lambda b: b['mean'])
        slowest = max(benches, key=lambda b: b['mean'])
        total_mean = sum(b['mean'] for b in benches)
        rows.append(
            f'<tr>'
            f'<td><strong>{escape(label)}</strong></td>'
            f'<td class="num">{len(benches)}</td>'
            f'<td class="name">{escape(fastest["name"])}<br>'
            f'<small style="color:#666">{fastest["mean"]:.3f} ms</small></td>'
            f'<td class="name">{escape(slowest["name"])}<br>'
            f'<small style="color:#666">{slowest["mean"]:.3f} ms</small></td>'
            f'<td class="num">{total_mean:.3f}</td>'
            f'</tr>'
        )
    return (
        '<table class="summary-table">'
        '<thead><tr>'
        '<th>Suite</th><th>#</th><th>Fastest (mean)</th><th>Slowest (mean)</th>'
        '<th>Sum of means (ms)</th>'
        '</tr></thead>'
        '<tbody>' + ''.join(rows) + '</tbody>'
        '</table>'
    )

def build_html(title, timestamp, git_sha, suites):
    chart_scripts = []
    suite_sections = []
    for idx, (label, runs, warmup, benches) in enumerate(suites):
        esc_label = escape(label)
        if not benches:
            suite_sections.append(
                f'<div class="suite"><h2>{esc_label}</h2><p><em>No results.</em></p></div>'
            )
            continue
        sid = f'chart_{idx}'
        n = len(benches)
        # Scale canvas height to the number of bars (each ~38px, minimum 180px)
        ch = max(180, n * 38 + 60)
        runs_str   = str(runs)   if runs   is not None else '?'
        warmup_str = str(warmup) if warmup is not None else '?'
        suite_sections.append(
            f'<div class="suite">'
            f'<h2>{esc_label} '
            f'<small style="font-weight:400;color:#888;font-size:0.8rem">'
            f'{runs_str} runs · {warmup_str} warmup</small></h2>'
            f'<div class="suite-body">'
            f'<div class="chart-wrap" style="max-height:{ch}px">'
            f'<canvas id="{sid}"></canvas>'
            f'</div>'
            + suite_table(benches) +
            f'</div></div>'
        )
        chart_scripts.append(suite_chart_js(sid, benches))

    sha_span = f'<span>commit <code>{escape(git_sha)}</code></span>' if git_sha else ''
    total_benches = sum(len(b) for _, _, _, b in suites)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)}</title>
<style>{CSS}</style>
</head>
<body>
<h1>{escape(title)}</h1>
<p class="meta">
  <span>{timestamp}</span>
  {sha_span}
  <span>{len(suites)} suite(s) · {total_benches} benchmark(s)</span>
</p>

<div class="suite">
  <h2>Overview</h2>
  {overall_summary_table(suites)}
</div>

{''.join(suite_sections)}

<script src="{CHARTJS_CDN}"></script>
{''.join(chart_scripts)}
</body>
</html>"""

# ─── GitHub step summary (Markdown) ──────────────────────────────────────────

def github_summary(title, suites):
    lines = [f'## {title}\n']
    for label, runs, warmup, benches in suites:
        if not benches:
            continue
        runs_str   = str(runs)   if runs   is not None else '?'
        warmup_str = str(warmup) if warmup is not None else '?'
        lines.append(f'### {label} ({runs_str} runs, {warmup_str} warmup)\n')
        lines.append('| Benchmark | min ms | mean ms | max ms |')
        lines.append('|---|---:|---:|---:|')
        for b in benches:
            lines.append(
                f'| `{b["name"]}` | {b["min"]:.3f} | {b["mean"]:.3f} | {b["max"]:.3f} |'
            )
        lines.append('')
    return '\n'.join(lines)

# ─── Entry point ─────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('results', nargs='+', metavar='FILE',
                    help='lyric bench output files')
    ap.add_argument('--output', default='bench-report.html', metavar='HTML',
                    help='output HTML path (default: bench-report.html)')
    ap.add_argument('--title', default='Lyric Performance Report',
                    help='report title')
    ap.add_argument('--git-sha', default='', metavar='SHA',
                    help='git commit SHA to embed in the report header')
    ap.add_argument('--summary-file', default='', metavar='FILE',
                    help='write GitHub-flavoured Markdown summary to this file '
                         '(append to $GITHUB_STEP_SUMMARY)')
    args = ap.parse_args()

    suites = []
    for path in args.results:
        try:
            suites.append(parse_result(path))
        except Exception as exc:
            print(f'warning: could not parse {path}: {exc}', file=sys.stderr)

    if not suites:
        print('error: no results parsed', file=sys.stderr)
        sys.exit(1)

    ts = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    html = build_html(args.title, ts, args.git_sha, suites)

    with open(args.output, 'w') as f:
        f.write(html)
    print(f'Report written to {args.output}')

    if args.summary_file:
        summary = github_summary(args.title, suites)
        with open(args.summary_file, 'a') as f:
            f.write(summary)
        print(f'Summary appended to {args.summary_file}')


if __name__ == '__main__':
    main()
