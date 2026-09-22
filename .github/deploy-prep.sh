#!/usr/bin/env bash
# Prepare the docs/ tree for whatever ref is currently checked out.
#
# Runs on the deploy runner, not on the pushed ref: the deploy jobs read this
# file from main (`git show origin/main:.github/deploy-prep.sh`) so a frozen
# docs/vX.Y.Z branch never has to carry it.
#
# Site chrome is not a release fact. Nav, theme and stylesheets come from main
# for every version, so fixing them is one commit instead of one per snapshot.
# Only the .md content is version-specific.
set -euo pipefail

git fetch -q origin main
git checkout origin/main -- zensical.toml stylesheets assets overrides

# Rebuild from scratch: a batch run reuses the worktree for several refs, and
# a stale page from the previous ref must not survive into the next version.
rm -rf docs
mkdir -p docs
cp README.md docs/index.md
# root-level pages other than README.md are not picked up by the directory
# loop below, so copy them explicitly
[ -f service-interactions.md ] && cp service-interactions.md docs/service-interactions.md || true
for d in battery battery-charger bluetooth dashboard electronic mechanical nrf redis services states tools wiring; do
  [ -d "$d" ] && cp -r "$d" "docs/$d"
done
[ -d stylesheets ] && cp -r stylesheets docs/stylesheets || true
[ -d assets ] && cp -r assets docs/assets || true

# main's nav lists pages that older snapshots legitimately do not have
# (event-service, motion-service, the BLE OTA page). Drop those entries,
# and any section left with no pages, rather than emitting dead links.
python3 - <<'PY'
import os, sys, tomllib

cfg = "zensical.toml"
raw = open(cfg, encoding="utf-8").read()
nav = tomllib.loads(raw).get("project", {}).get("nav")
if not nav:
    print("no nav to prune"); sys.exit(0)

dropped = []

def keep(entry):
    (title, val), = entry.items()
    if isinstance(val, str):
        if os.path.exists(os.path.join("docs", val)):
            return {title: val}
        dropped.append(val)
        return None
    kids = [k for k in (keep(c) for c in val) if k]
    if not kids:
        dropped.append(title + " (section, no remaining pages)")
        return None
    return {title: kids}

pruned = [e for e in (keep(x) for x in nav) if e]

def emit(entries, indent=4):
    pad = " " * indent
    out = []
    for e in entries:
        (title, val), = e.items()
        if isinstance(val, str):
            out.append(pad + '{ "' + title + '" = "' + val + '" },')
        else:
            out.append(pad + '{ "' + title + '" = [')
            out.extend(emit(val, indent + 4))
            out.append(pad + "]},")
    return out

start = raw.index("nav = [")
depth, i = 0, raw.index("[", start)
while True:
    if raw[i] == "[": depth += 1
    elif raw[i] == "]": depth -= 1
    if depth == 0: break
    i += 1
open(cfg, "w", encoding="utf-8").write(
    raw[:start] + "nav = [\n" + "\n".join(emit(pruned)) + "\n]" + raw[i+1:])

print("pruned %d nav entries not present in this version:" % len(dropped))
for d in dropped:
    print("  -", d)
PY
