#!/usr/bin/env python3
import argparse
import html
import json
import os
from datetime import datetime, timezone
from pathlib import Path


ROUTE_PREFIX = "http://127.0.0.1:3003"


def env(name: str) -> str:
    return os.environ[name]


def route_path(url: str) -> str:
    return url.replace(ROUTE_PREFIX, "")


def read_features() -> list[dict]:
    return json.loads(env("ZONO_FEATURE_BENCHMARKS"))


def build_snapshot() -> dict:
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    features = read_features()

    return {
        "timestamp": timestamp,
        "snapshot_id": timestamp.replace("-", "").replace(":", ""),
        "runner": "ubuntu-latest",
        "benchmark": {
            "tool": "wrk",
            "threads": int(env("BENCH_THREADS")),
            "connections": int(env("BENCH_CONNECTIONS")),
            "duration_seconds": int(env("BENCH_DURATION_SECONDS")),
            "warmup_seconds": int(env("BENCH_WARMUP_SECONDS")),
            "runs": int(env("BENCH_RUNS")),
            "aggregation": "median_requests_per_sec_with_matching_latency_distribution",
        },
        "target": {
            "zono_route": "/api/json",
            "merjs_route": "/api/json",
            "example": "benchmark",
            "zono_feature_routes": [route_path(item["url"]) for item in features],
        },
        "zono": {
            "requests_per_sec": float(env("ZONO_RPS")),
            "avg_latency": env("ZONO_LAT"),
            "latency_p50": env("ZONO_P50"),
            "latency_p75": env("ZONO_P75"),
            "latency_p90": env("ZONO_P90"),
            "latency_p99": env("ZONO_P99"),
            "ram_mb": float(env("ZONO_RAM_MB")),
            "binary_size": env("ZONO_BINARY_SIZE"),
            "binary_bytes": int(env("ZONO_BINARY_BYTES")),
            "source_files": int(env("ZONO_SOURCE_FILES")),
            "zig_version": env("ZONO_ZIG_VERSION"),
            "runtime_deps": env("ZONO_RUNTIME_DEPS"),
            "feature_benchmarks": features,
        },
        "merjs": {
            "requests_per_sec": float(env("MERJS_RPS")),
            "avg_latency": env("MERJS_LAT"),
            "latency_p50": env("MERJS_P50"),
            "latency_p75": env("MERJS_P75"),
            "latency_p90": env("MERJS_P90"),
            "latency_p99": env("MERJS_P99"),
            "ram_mb": float(env("MERJS_RAM_MB")),
            "binary_size": env("MERJS_BINARY_SIZE"),
            "binary_bytes": int(env("MERJS_BINARY_BYTES")),
            "source_files": int(env("MERJS_SOURCE_FILES")),
            "zig_version": env("MERJS_ZIG_VERSION"),
            "baseline_ref": env("MERJS_BASELINE_REF"),
            "runtime_deps": env("MERJS_RUNTIME_DEPS"),
        },
    }


def headline_rows(data: dict, markdown: bool = False) -> list[tuple[str, str, str]]:
    zono = data["zono"]
    merjs = data["merjs"]

    def strong(value: object) -> str:
        text = str(value)
        return f"**{text}**" if markdown else text

    rows = [
        (
            "Requests/sec (wrk median)" if markdown else "Requests/sec",
            strong(zono["requests_per_sec"]),
            strong(merjs["requests_per_sec"]),
        ),
        (
            "Avg latency (avg stdev)" if markdown else "Avg latency",
            zono["avg_latency"],
            merjs["avg_latency"],
        ),
        (
            "Latency p50" if markdown else "p50",
            zono["latency_p50"],
            merjs["latency_p50"],
        ),
        (
            "Latency p90" if markdown else "p90",
            zono["latency_p90"],
            merjs["latency_p90"],
        ),
        (
            "Latency p99" if markdown else "p99",
            zono["latency_p99"],
            merjs["latency_p99"],
        ),
        (
            "RAM usage (under load)" if markdown else "RAM",
            strong(f'{zono["ram_mb"]} MB'),
            strong(f'{merjs["ram_mb"]} MB'),
        ),
    ]
    if markdown:
        rows.insert(3, ("Latency p75", zono["latency_p75"], merjs["latency_p75"]))
    return rows


def render_markdown(data: dict) -> str:
    bench = data["benchmark"]
    lines = [
        "# zono benchmark snapshot",
        "",
        f'Generated: `{data["timestamp"]}`',
        "",
        (
            f'Tool: `{bench["tool"]}`, '
            f'`{bench["threads"]}t/{bench["connections"]}c/{bench["duration_seconds"]}s`, '
            f'median of `{bench["runs"]}` measured runs.'
        ),
        "",
        "## Headline",
        "",
        "| Metric | zono | merjs |",
        "|--------|------|-------|",
    ]
    lines.extend(
        f"| {metric} | {zono} | {merjs} |"
        for metric, zono, merjs in headline_rows(data, markdown=True)
    )
    lines.extend([
        "",
        "## zono feature matrix",
        "",
        "| Feature | Route | Requests/sec | Avg latency | p99 |",
        "|---------|-------|--------------|-------------|-----|",
    ])
    for item in data["zono"]["feature_benchmarks"]:
        lines.append(
            f'| {item["label"]} | `{route_path(item["url"])}` | '
            f'**{item["requests_per_sec"]:.2f}** | '
            f'{item["avg_latency"]} | {item["latency_p99"]} |'
        )
    return "\n".join(lines) + "\n"


def render_svg(data: dict) -> str:
    width = 920
    summary_y = 136
    row_h = 30
    feature_rows = data["zono"]["feature_benchmarks"]
    rows = headline_rows(data)
    headline_bottom_y = summary_y + row_h * (len(rows) - 1) + 8
    feature_y = headline_bottom_y + 32
    feature_row_y = feature_y + 28
    height = feature_row_y + max(1, len(feature_rows)) * 26 + 34

    def esc(value: object) -> str:
        return html.escape(str(value), quote=True)

    parts = [
        (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
            f'height="{height}" viewBox="0 0 {width} {height}" '
            f'role="img" aria-labelledby="title desc">'
        ),
        '<title id="title">Latest zono benchmark results</title>',
        f'<desc id="desc">Generated {esc(data["timestamp"])} from wrk benchmark results.</desc>',
        (
            '<style>text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;fill:#24292f}'
            '.muted{fill:#57606a}.title{font-size:24px;font-weight:700}.sub{font-size:13px}'
            '.head{font-size:13px;font-weight:700}.cell{font-size:13px}.num{font-size:13px;font-weight:700}'
            '.small{font-size:12px}</style>'
        ),
        f'<rect x="0.5" y="0.5" width="{width - 1}" height="{height - 1}" rx="8" fill="#ffffff" stroke="#d0d7de"/>',
        '<text id="title-text" class="title" x="28" y="42">zono benchmark</text>',
        (
            f'<text class="sub muted" x="28" y="66">Generated {esc(data["timestamp"])} - '
            f'wrk {data["benchmark"]["threads"]}t/{data["benchmark"]["connections"]}c/'
            f'{data["benchmark"]["duration_seconds"]}s - median of {data["benchmark"]["runs"]} runs</text>'
        ),
        '<text class="head" x="28" y="110">Headline</text>',
        '<text class="head muted" x="330" y="110">zono</text>',
        '<text class="head muted" x="555" y="110">merjs</text>',
    ]

    y = summary_y
    for index, (metric, zono, merjs) in enumerate(rows):
        fill = "#f6f8fa" if index % 2 == 0 else "#ffffff"
        parts.extend([
            f'<rect x="20" y="{y - 20}" width="880" height="28" fill="{fill}"/>',
            f'<text class="cell" x="28" y="{y}">{esc(metric)}</text>',
            f'<text class="num" x="330" y="{y}">{esc(zono)}</text>',
            f'<text class="num" x="555" y="{y}">{esc(merjs)}</text>',
        ])
        y += row_h

    parts.extend([
        f'<text class="head" x="28" y="{feature_y}">zono feature matrix</text>',
        f'<text class="head muted" x="330" y="{feature_y}">Requests/sec</text>',
        f'<text class="head muted" x="485" y="{feature_y}">Avg latency</text>',
        f'<text class="head muted" x="615" y="{feature_y}">p99</text>',
    ])

    y = feature_row_y
    for index, item in enumerate(feature_rows):
        fill = "#f6f8fa" if index % 2 == 0 else "#ffffff"
        parts.extend([
            f'<rect x="20" y="{y - 18}" width="880" height="24" fill="{fill}"/>',
            f'<text class="cell" x="28" y="{y}">{esc(item["label"])} - {esc(route_path(item["url"]))}</text>',
            f'<text class="num" x="330" y="{y}">{item["requests_per_sec"]:.2f}</text>',
            f'<text class="cell" x="485" y="{y}">{esc(item["avg_latency"])}</text>',
            f'<text class="cell" x="615" y="{y}">{esc(item["latency_p99"])}</text>',
        ])
        y += 26

    parts.append(
        f'<text class="small muted" x="28" y="{height - 22}">'
        "Raw JSON and markdown summary live on the benchmarks branch.</text>"
    )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def write_snapshot(out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    history_dir = out_dir / "history"
    history_dir.mkdir(parents=True, exist_ok=True)

    data = build_snapshot()
    snapshot_id = data["snapshot_id"]
    files = {
        "json": json.dumps(data, indent=2) + "\n",
        "md": render_markdown(data),
        "svg": render_svg(data),
    }

    for suffix, content in files.items():
        (out_dir / f"latest.{suffix}").write_text(content, encoding="utf-8")
        (history_dir / f"{snapshot_id}.{suffix}").write_text(content, encoding="utf-8")

    print(files["json"])


def write_history_index(root: Path) -> None:
    entries = []
    for path in sorted((root / "history").glob("*.json"), reverse=True):
        data = json.loads(path.read_text(encoding="utf-8"))
        snapshot_id = data.get("snapshot_id") or path.stem
        entries.append({
            "snapshot_id": snapshot_id,
            "timestamp": data.get("timestamp"),
            "json": f"history/{snapshot_id}.json",
            "markdown": f"history/{snapshot_id}.md",
            "svg": f"history/{snapshot_id}.svg",
            "zono_requests_per_sec": data.get("zono", {}).get("requests_per_sec"),
            "zono_latency_p99": data.get("zono", {}).get("latency_p99"),
            "merjs_requests_per_sec": data.get("merjs", {}).get("requests_per_sec"),
            "merjs_latency_p99": data.get("merjs", {}).get("latency_p99"),
        })

    index = {
        "latest": entries[0] if entries else None,
        "count": len(entries),
        "entries": entries,
    }
    (root / "history.json").write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    render_parser = subparsers.add_parser("render")
    render_parser.add_argument("out_dir", type=Path)
    index_parser = subparsers.add_parser("index")
    index_parser.add_argument("root", type=Path)
    args = parser.parse_args()

    if args.command == "render":
        write_snapshot(args.out_dir)
    else:
        write_history_index(args.root)


if __name__ == "__main__":
    main()
