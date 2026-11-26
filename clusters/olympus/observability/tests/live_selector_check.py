"""Live check of every metric selector in the alert rules and Grafana dashboards against a running Prometheus
(olympus-gitops#115). Run it after a Kubernetes, k3s, exporter or collector upgrade.

For each selector (metric name plus the label matchers that are not Grafana variables) it asks Prometheus for
series now and over the last 7 days, and prints those with none now:

  source | panel or alert | metric | series now | series in 7d | selector

"0 now, >0 in 7d" is a sparse or event metric (pushed, delta-exported, or absent while healthy) and usually fine.
"0 and 0" is an event that has not happened yet, a collector that is off, or a renamed or missing metric: compare
the metric name with Prometheus's /api/v1/label/__name__/values. Grafana variables are dropped from matchers and
variable ranges ($__rate_interval, $interval) become 5m, so a selector is checked as broadly as the dashboard
allows. Targets on a Loki datasource (LogQL) are listed as skipped, not checked.

Needs PyYAML. Dashboards imported from grafana.com (`gnetId` in grafana-helmrelease.yaml) are not in the repo;
download them first, e.g. https://grafana.com/api/dashboards/1860/revisions/45/download. From this directory's
parent:

  python3 tests/live_selector_check.py http://obs-prometheus:9090 prometheus-helmrelease.yaml dashboards/*.json 1860.json
"""

import json
import re
import sys
import urllib.parse
import urllib.request

import yaml

PROM = sys.argv[1]


def api(path, **params):
    data = urllib.parse.urlencode(params).encode()
    with urllib.request.urlopen(urllib.request.Request(PROM + path, data=data), timeout=60) as r:
        return json.load(r)


def grafana_subst(e):
    for var, val in (("__rate_interval", "5m"), ("__interval", "1m"), ("__range", "1h")):
        e = e.replace("${" + var + "}", val).replace("$" + var, val)
    e = re.sub(r"\[\s*\$\{?\w+\}?\s*(:\s*\$?\{?\w*\}?)?\]", "[5m]", e)
    e = re.sub(r"\$\{(\w+)(:\w+)?\}", "__VAR__", e)
    return re.sub(r"\$(\w+)", "__VAR__", e)


def walk(node, out):
    if isinstance(node, dict):
        if node.get("type") in ("vectorSelector", "matrixSelector") and "matchers" in node:
            out.append(node)
        for v in node.values():
            walk(v, out)
    elif isinstance(node, list):
        for v in node:
            walk(v, out)


exprs = []  # (source, panel or alert, expression)
skipped_loki = []  # (dashboard, panel): LogQL targets, not Prometheus


def rules_exprs(path):
    def rec(n):
        if isinstance(n, dict):
            if isinstance(n.get("expr"), str) and ("alert" in n or "record" in n):
                exprs.append((path.split("/")[-1], n.get("alert") or n.get("record"), n["expr"]))
            for v in n.values():
                rec(v)
        elif isinstance(n, list):
            for v in n:
                rec(v)

    for d in yaml.safe_load_all(open(path)):
        rec(d)


def dash_exprs(path):
    d = json.load(open(path))
    title = d.get("title", path)

    def is_loki(n):
        ds = n.get("datasource")
        return isinstance(ds, dict) and ds.get("type") == "loki" or isinstance(ds, str) and "loki" in ds.lower()

    def rec(n, panel):
        if isinstance(n, dict):
            p = n.get("title", panel) if "targets" in n or "panels" in n else panel
            if isinstance(n.get("expr"), str) and n["expr"].strip():
                if is_loki(n):
                    skipped_loki.append((title, p))
                else:
                    exprs.append((title, p, n["expr"]))
            q = n.get("query")
            if isinstance(q, dict):
                q = q.get("query")
            if isinstance(q, str) and n.get("type") == "query":
                m = re.match(r"\s*(label_values|query_result)\((.*)\)\s*$", q, re.S)
                if m:
                    inner = m.group(2)
                    lv = re.match(r"(.*),\s*\w+\s*$", inner, re.S)
                    expr = lv.group(1) if lv and m.group(1) == "label_values" else inner
                    if expr.strip():
                        exprs.append((title, "var " + n.get("name", "?"), expr))
            for v in n.values():
                rec(v, p)
        elif isinstance(n, list):
            for v in n:
                rec(v, panel)

    rec(d, "")


for f in sys.argv[2:]:
    (rules_exprs if f.endswith((".yaml", ".yml")) else dash_exprs)(f)

cache = {}
missing = set()
not_parsed = []
for src, label, e in exprs:
    try:
        ast = api("/api/v1/parse_query", query=grafana_subst(e))["data"]
    except Exception as ex:  # noqa: BLE001
        not_parsed.append((src, label, str(ex)[:80]))
        continue
    sels = []
    walk(ast, sels)
    for s in sels:
        ms = [m for m in s["matchers"] if "__VAR__" not in m["value"]]
        name = next((m["value"] for m in ms if m["name"] == "__name__" and m["type"] == "="), "")
        sel = "{" + ",".join(f'{m["name"]}{m["type"]}{json.dumps(m["value"])}' for m in ms) + "}"
        if sel not in cache:
            r = api("/api/v1/query", query=f"count({sel})")["data"]["result"]
            now = int(float(r[0]["value"][1])) if r else 0
            week = None
            if now == 0:
                r7 = api("/api/v1/query", query=f"count(last_over_time({sel}[7d]))")["data"]["result"]
                week = int(float(r7[0]["value"][1])) if r7 else 0
            cache[sel] = (now, week)
        now, week = cache[sel]
        if now == 0:
            missing.add((src, label, name, now, week, sel))

for row in sorted(missing):
    print(" | ".join(str(x) for x in row))
print(f"# {len(exprs)} expressions, {len(cache)} selectors, {len(missing)} with no series now")
for row in not_parsed:
    print("# not parsed:", " | ".join(row))
for row in sorted(set(skipped_loki)):
    print("# skipped (Loki datasource, LogQL):", " | ".join(row))
