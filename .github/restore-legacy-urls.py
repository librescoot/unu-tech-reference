#!/usr/bin/env python3
"""Re-create the URL space the reference site had before it moved to mike.

Until 93f3842 (2026-05-08) the `stable` branch was built straight into the
site root, so the docs lived unversioned at /services/librescoot-battery/ and
so on. Switching to mike replaced gh-pages with an orphan history and moved
every page under /vX.Y.Z/, which left ~28 URLs that Search Console still knew
about returning 404 (all last crawled 2026-05-28 .. 2026-06-14).

mike never deletes unrelated files at the gh-pages root - the CNAME stamping
in deploy-impl.yml already depends on that - so writing the stubs once would
probably stick. Re-stamping them on every deploy is cheap and also survives
someone resetting gh-pages.

Targets point at the /stable/ alias rather than a version directory so a
promotion keeps old links resolving to the current release.

The paths come from the `stable` branch's zensical.toml nav plus the one
built-but-unlinked page under bluetooth/utils. Every target has been checked
to exist.

Usage: restore-legacy-urls.py <gh-pages worktree>
"""

import pathlib
import sys

SITE = "https://reference.librescoot.org"
TARGET_BASE = f"{SITE}/stable"

# Relative paths, no leading slash. These are the URLs the pre-mike root
# served; they are also the ones Search Console reports as Not found (404).
LEGACY_PATHS = (
    "electronic/",
    "mechanical/",
    "wiring/",
    "battery/",
    "battery-charger/",
    "bluetooth/",
    "bluetooth/utils/decode_logs/",
    "redis/",
    "nrf/",
    "nrf/UART/",
    "nrf/power-management/",
    "states/",
    "services/",
    "services/librescoot-alarm/",
    "services/librescoot-battery/",
    "services/librescoot-bluetooth/",
    "services/librescoot-ecu/",
    "services/librescoot-keycard/",
    "services/librescoot-modem/",
    "services/librescoot-pm/",
    "services/librescoot-scootui/",
    "services/librescoot-settings/",
    "services/librescoot-ums/",
    "services/librescoot-update/",
    "services/librescoot-vehicle/",
    "dashboard/",
    "dashboard/REDIS/",
    "tools/lsc/",
)

# Same shape as the site's own redirect layout: canonical names the target so
# the old URL consolidates onto it, noindex keeps the stub itself out of the
# index, and the meta refresh does the moving for anything that ignores the
# script.
STUB = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Redirecting&hellip;</title>
<link rel="canonical" href="{target}">
<script>location="{target}"</script>
<meta http-equiv="refresh" content="0; url={target}">
<meta name="robots" content="noindex">
</head>
<body>
<h1>Redirecting&hellip;</h1>
<a href="{target}">Click here if you are not redirected.</a>
</body>
</html>
"""


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    root = pathlib.Path(argv[1])
    if not root.is_dir():
        print(f"{root} is not a directory", file=sys.stderr)
        return 1

    added = updated = unchanged = 0
    for path in LEGACY_PATHS:
        target = f"{TARGET_BASE}/{path}"
        stub = root / path / "index.html"
        body = STUB.format(target=target)

        if stub.exists() and stub.read_text(encoding="utf-8") == body:
            unchanged += 1
            continue

        existed = stub.exists()
        stub.parent.mkdir(parents=True, exist_ok=True)
        stub.write_text(body, encoding="utf-8")
        if existed:
            updated += 1
        else:
            added += 1

    print(f"legacy redirects: {added} added, {updated} updated, {unchanged} unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
