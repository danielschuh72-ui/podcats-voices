#!/usr/bin/env python3
# Prints the id of an available iPhone simulator on the newest iOS runtime installed.
import json, re, subprocess
devs = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
best = None
for runtime, items in devs.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    ver = (int(m.group(1)), int(m.group(2)))
    for d in items:
        if d["name"].startswith("iPhone") and "SE" not in d["name"]:
            rank = (ver, "Pro" in d["name"] and "Max" not in d["name"], d["name"])
            if best is None or rank > best[0]:
                best = (rank, d["udid"], d["name"], runtime)
if not best:
    raise SystemExit("no iPhone simulator available")
import sys
print(best[2], best[3], file=sys.stderr)
print(best[1])
