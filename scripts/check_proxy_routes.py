#!/usr/bin/env python3
"""Assert the edge proxy routes every path the application actually serves.

`nginx -t` only proves the configuration parses. It cannot tell you that
`/api/health` is being sent to the frontend instead of the API -- which is
exactly the failure that left the node reporting:

    FAIL  GET http://192.168.10.131/api/health failed

while every container was healthy and the home page loaded fine. A single
catch-all `location /` in the plain-HTTP server was proxying every request to
the frontend, so /api/, /admin/, /uploads/ and /ws/ were all silently wrong.
Nothing errored; the app was just unusable.

So this asserts intent: for each path prefix the app depends on, that a
location exists AND that it is wired to the correct upstream. If someone
collapses the route table to a catch-all, renames a variable, or points a
path at the wrong backend, this fails before it ships.

Kept deliberately small and declarative -- it is a routing contract, not a
second copy of the nginx config.

Usage:
    python3 scripts/check_proxy_routes.py [nginx-dir]
"""

import pathlib
import re
import sys

DEFAULT_DIR = pathlib.Path("nginx/conf.d")

# path prefix -> (upstream variable, what breaks if this is wrong)
ROUTE_CONTRACT = {
    "/api/": ("$api_upstream", "every REST call, including the health probe"),
    "/admin/": ("$api_upstream", "the admin API"),
    "/uploads/": ("$api_upstream", "device images and room documents"),
    "/ws/": ("$api_upstream", "Socket.IO, including the WebSocket upgrade"),
    "/static/": ("$frontend_upstream", "the built SPA's static assets"),
    "/": ("$frontend_upstream", "the SPA itself"),
}


def strip_comments(text):
    out = []
    for line in text.split("\n"):
        in_s = in_d = False
        cut = len(line)
        for i, ch in enumerate(line):
            if ch == "'" and not in_d:
                in_s = not in_s
            elif ch == '"' and not in_s:
                in_d = not in_d
            elif ch == "#" and not in_s and not in_d:
                cut = i
                break
        out.append(line[:cut])
    return "\n".join(out)


def parse_locations(text):
    """Map location prefix -> proxy_pass target, from one file's text."""
    routes = {}
    # Each location block, captured with its body.
    for match in re.finditer(r"location\s+([^\s{]+)\s*\{([^{}]*)\}", text, re.S):
        prefix, body = match.group(1), match.group(2)
        upstream = re.search(r"proxy_pass\s+(\$\w+)", body)
        routes[prefix] = upstream.group(1) if upstream else None
    return routes


def main(argv):
    confd = pathlib.Path(argv[1] if len(argv) > 1 else DEFAULT_DIR)

    # The shared route table is the single source of truth for both servers.
    candidates = sorted(confd.glob("*.inc")) + sorted(confd.glob("*.conf"))
    routes = {}
    where = {}
    for path in candidates:
        text = strip_comments(path.read_text(encoding="utf-8"))
        for prefix, upstream in parse_locations(text).items():
            # First file to define a prefix wins; proxy-locations.inc comes
            # first alphabetically among .inc, which is the intended owner.
            if prefix not in routes:
                routes[prefix] = upstream
                where[prefix] = path

    problems = []
    for prefix, (expected, why) in ROUTE_CONTRACT.items():
        if prefix not in routes:
            problems.append(
                f"no `location {prefix}` block is defined; {why} would 404 or be "
                f"routed to the wrong backend"
            )
            continue
        actual = routes[prefix]
        if actual != expected:
            problems.append(
                f"`location {prefix}` proxies to {actual or '<no proxy_pass>'}, "
                f"expected {expected}; {why} is broken"
            )

    for problem in problems:
        print(f"::error::{problem}")

    if problems:
        return 1

    print(f"  proxy routes OK ({len(ROUTE_CONTRACT)} paths, correct upstreams)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
