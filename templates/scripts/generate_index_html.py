#!/usr/bin/env python3
"""
Generate a minimal static dashboard index.html listing recent pytest runs.

Lists every `<s3-prefix>/<env>/<timestamp>/report.html` under the configured
S3 bucket, grouped by environment, newest first.

Env vars:
    S3_BUCKET      (required)
    S3_PREFIX      (default: "pytest-reports/")
    INDEX_OUTPUT   (default: "/tmp/index.html")
    PROJECT_NAME   (default: "pytest-api-kit")
    AWS_REGION     (default: boto3 default)

Usage:
    S3_BUCKET=my-reports python3 generate_index_html.py
    aws s3 cp /tmp/index.html s3://my-reports/index.html --content-type text/html
"""
import html
import json
import os
import re
from datetime import datetime
from pathlib import Path

import boto3  # AWS SDK

S3_BUCKET = os.environ["S3_BUCKET"]
S3_PREFIX = os.environ.get("S3_PREFIX", "pytest-reports/")
OUT_PATH = Path(os.environ.get("INDEX_OUTPUT", "/tmp/index.html"))
PROJECT_NAME = os.environ.get("PROJECT_NAME", "pytest-api-kit")

s3 = boto3.client("s3")

# ---------------------------------------------------------------------------
# Collect all report.html keys
# ---------------------------------------------------------------------------
paginator = s3.get_paginator("list_objects_v2")
report_objs = []
for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=S3_PREFIX):
    for obj in page.get("Contents", []):
        key = obj["Key"]
        if key.endswith("/report.html"):
            # Expected layout: {prefix}/{env}/{timestamp}/report.html
            m = re.match(
                rf"^{re.escape(S3_PREFIX)}(?P<env>[^/]+)/(?P<ts>[^/]+)/report\.html$",
                key,
            )
            if not m:
                continue
            report_objs.append({
                "env": m.group("env"),
                "ts": m.group("ts"),
                "key": key,
                "last_modified": obj["LastModified"],
            })

# Attach summary counts if summary.json exists alongside the report
for r in report_objs:
    summary_key = r["key"].replace("/report.html", "/summary.json")
    try:
        body = s3.get_object(Bucket=S3_BUCKET, Key=summary_key)["Body"].read()
        d = json.loads(body)
        r["summary"] = {
            "tests": d.get("tests", 0),
            "failures": d.get("failures", 0) + d.get("errors", 0),
            "skipped": d.get("skipped", 0),
            "run_type": d.get("run_type", "full"),
        }
    except Exception:
        r["summary"] = None

# Group by env, sort newest first
by_env = {}
for r in report_objs:
    by_env.setdefault(r["env"], []).append(r)
for env in by_env:
    by_env[env].sort(key=lambda r: r["ts"], reverse=True)

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
def fmt_ts(ts: str) -> str:
    """Parse 20260423-101530 -> '2026-04-23 10:15'."""
    try:
        dt = datetime.strptime(ts, "%Y%m%d-%H%M%S")
        return dt.strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return ts


def status_badge(s):
    if not s:
        return '<span style="color:#94a3b8">—</span>'
    fails = s["failures"]
    total = s["tests"]
    if total == 0:
        return '<span style="color:#94a3b8">empty</span>'
    if fails == 0:
        color = "#059669"
        return f'<span style="color:{color}">✓ {total}</span>'
    ratio = fails / total
    color = "#d97706" if ratio < 0.1 else "#dc2626"
    return f'<span style="color:{color}">✗ {fails}/{total}</span>'


rows = []
for env in sorted(by_env.keys()):
    rows.append(f'<h2>{html.escape(env.upper())}</h2>')
    rows.append('<table><thead><tr>'
                '<th>Time</th><th>Run type</th><th>Result</th><th>Link</th>'
                '</tr></thead><tbody>')
    for r in by_env[env][:30]:  # show latest 30 per env
        url = f"/{r['key']}"
        rt = (r.get("summary") or {}).get("run_type", "?")
        rows.append(
            f'<tr><td>{fmt_ts(r["ts"])}</td>'
            f'<td>{html.escape(rt)}</td>'
            f'<td>{status_badge(r.get("summary"))}</td>'
            f'<td><a href="{url}?sort=result">open</a></td></tr>'
        )
    rows.append('</tbody></table>')

body_html = "\n".join(rows) if rows else "<p>No reports yet.</p>"

generated_at = datetime.now().strftime("%Y-%m-%d %H:%M")

out = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{html.escape(PROJECT_NAME)} — Test reports</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         max-width: 900px; margin: 2em auto; padding: 0 1em; color: #1e293b; }}
  h1 {{ border-bottom: 2px solid #e2e8f0; padding-bottom: .3em; }}
  h2 {{ margin-top: 2em; color: #475569; }}
  table {{ width: 100%; border-collapse: collapse; }}
  th, td {{ padding: .4em .6em; border-bottom: 1px solid #e2e8f0; text-align: left; }}
  th {{ background: #f8fafc; font-weight: 600; font-size: .85em; }}
  tr:hover td {{ background: #f8fafc; }}
  a {{ color: #2563eb; text-decoration: none; }}
  a:hover {{ text-decoration: underline; }}
  footer {{ margin-top: 3em; color: #94a3b8; font-size: .8em; text-align: right; }}
</style>
</head>
<body>
<h1>{html.escape(PROJECT_NAME)} — Test reports</h1>
{body_html}
<footer>Generated {generated_at} · S3 bucket <code>{html.escape(S3_BUCKET)}</code></footer>
</body>
</html>
"""

OUT_PATH.write_text(out, encoding="utf-8")
print(f"index.html written: {OUT_PATH} ({len(out)} bytes, {len(report_objs)} reports)")
