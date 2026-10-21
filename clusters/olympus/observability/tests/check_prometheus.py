#!/usr/bin/env python3
"""Validate the Prometheus scrape jobs and alert rules embedded in prometheus-helmrelease.yaml.

  promtool check config   extraScrapeConfigs, wrapped in a minimal prometheus.yml
  promtool check rules    serverFiles.alerting_rules.yml
  promtool test rules     tests/*.test.yaml (e.g. the memory gateway alerts)

Needs promtool (Prometheus 3.x) on PATH and PyYAML. Run from anywhere:
  python3 clusters/olympus/observability/tests/check_prometheus.py
"""
import glob
import os
import shutil
import subprocess
import sys
import tempfile

import yaml

here = os.path.dirname(os.path.abspath(__file__))
release = yaml.safe_load(open(os.path.join(here, "..", "prometheus-helmrelease.yaml")))
values = release["spec"]["values"]

with tempfile.TemporaryDirectory() as work:
    with open(os.path.join(work, "prometheus.yml"), "w") as out:
        yaml.safe_dump(
            {"global": {"scrape_interval": "1m"}, "scrape_configs": yaml.safe_load(values["extraScrapeConfigs"])},
            out,
            sort_keys=False,
        )
    with open(os.path.join(work, "alerting_rules.yml"), "w") as out:
        yaml.safe_dump(values["serverFiles"]["alerting_rules.yml"], out, sort_keys=False)
    tests = sorted(glob.glob(os.path.join(here, "*.test.yaml")))
    for test in tests:
        shutil.copy(test, work)

    steps = [
        ["promtool", "check", "config", "prometheus.yml"],
        ["promtool", "check", "rules", "alerting_rules.yml"],
        ["promtool", "test", "rules", *[os.path.basename(t) for t in tests]],
    ]
    for step in steps:
        print("+", " ".join(step), flush=True)
        if subprocess.run(step, cwd=work).returncode != 0:
            sys.exit(1)
