#!/usr/bin/env python3
"""Static check for the Nginx configuration shipped in this repo.

This exists because three separate start-up failures reached production from
this configuration, and none was caught in CI:

  1. A `listen 443 ssl` server block naming a certificate that does not exist
     yet. nginx loads every conf.d/*.conf at boot, so "cannot load
     certificate" is fatal and the container never starts -- which made a
     first install unreachable on port 80 as well.
  2. `set $api_upstream` placed in the http context of nginx.conf. `set` is
     only valid in a server, location or if block, so nginx aborts with
     [emerg] "set" directive is not allowed here.
  3. A `proxy_pass $var` whose `set $var` was defined in a different file than
     the one using it, which is a runtime failure, not a start-up one.

`nginx -t` in CI only ever tested the *built frontend image*, which bundles its
own copy of this config and is not the config edge-nginx mounts from the host.
So the mounted configuration was never validated at all.

This is a structural check, deliberately not a full nginx parser: it verifies
the rules that were actually broken. Run it in CI and before any deploy that
touches nginx/.

Usage:
    python3 scripts/check_nginx_config.py [nginx-dir]
"""

import pathlib
import re
import sys

DEFAULT_DIR = pathlib.Path("nginx")

# Directives that are only legal inside server/location/if. `set` is the one
# that bit us; the others are listed so the same mistake is caught early.
SERVER_ONLY = {"set"}

# Directives that require a certificate to be present at load time.
CERT_DIRECTIVES = ("ssl_certificate", "ssl_certificate_key")

# Files nginx loads automatically. Anything ending in .conf here is loaded on
# every boot, so it must not depend on files that may not exist yet.
LOADED_SUFFIX = ".conf"

# Files pulled in by an explicit `include`. nginx does not auto-load these, but
# they hold the actual route table, so they must be validated too: the routing
# regression that broke /api/health lived in exactly this kind of file, and a
# scan limited to *.conf never saw it.
INCLUDE_SUFFIX = ".inc"

# nginx keeps several directives as single-instance: appearing twice in the SAME
# context is a fatal [emerg] "directive is duplicate", not a warning and not an
# override. This bit us because proxy_http_version was set inline in /ws/ and
# location / *and* in the shared proxy-headers.conf that both include -- the
# edge container crash-looped on every start and CI's nginx -t step caught it.
#
# Deliberately conservative: only directives that are genuinely single-instance
# are listed, because a false positive here trains people to ignore the check.
# Multi-instance directives that are safe to repeat (proxy_set_header,
# proxy_pass, add_header, limit_req, error_page, access_log, include) are
# intentionally absent.
SINGLE_INSTANCE = frozenset(
    {
        "proxy_http_version",
        "client_max_body_size",
        "proxy_connect_timeout",
        "proxy_send_timeout",
        "proxy_read_timeout",
        "proxy_buffering",
        "proxy_request_buffering",
        "client_body_timeout",
        "client_header_timeout",
        "send_timeout",
        "sendfile",
        "keepalive_timeout",
        "server_tokens",
        "default_type",
        "root",
        "index",
        "expires",
        "gzip",
        "worker_processes",
        "worker_connections",
    }
)

INCLUDE_RE = re.compile(r"^\s*include\s+(\S+?);")
DIRECTIVE_RE = re.compile(r"^\s*([a-z_]+)\b")
BLOCK_OPEN_RE = re.compile(r"^\s*([a-z_]+)\s+([^;{]*?)\s*\{\s*$")


def strip_strings(line):
    """Blank out quoted content so brace counting ignores braces in strings."""
    return re.sub(r'"[^"]*"|\'[^\']*\'', '""', line)


def expand_includes(confd, path, problems, chain=()):
    """Flatten a config file with every `include` expanded in place.

    Returns a list of (file, lineno, text) in nginx's own load order. Expansion
    has to happen before any block analysis: a duplicate only exists once the
    included file's directives land in the same block as the including file's,
    which no per-file line scan can see.
    """
    key = str(path)
    if key in chain:
        problems.append(
            f"{path}: includes itself (via {' -> '.join(chain)}); nginx would "
            f"expand this forever"
        )
        return []

    out = []
    for lineno, raw in enumerate(
        strip_comments(path.read_text(encoding="utf-8")).split("\n"), start=1
    ):
        inc = INCLUDE_RE.match(raw)
        if not inc:
            out.append((path, lineno, raw))
            continue
        target = confd / inc.group(1).rsplit("/", 1)[-1]
        if not target.exists():
            problems.append(
                f"{path}:{lineno}: includes {inc.group(1)}, which does not exist; "
                f"nginx refuses to start on a missing include"
            )
            continue
        out.extend(expand_includes(confd, target, problems, chain + (key,)))
    return out


def find_duplicate_directives(expanded):
    """Report single-instance directives used twice in the same block."""
    problems = []
    stack = [{}]
    labels = ["<top level>"]

    for path, lineno, raw in expanded:
        line = raw.strip()
        if not line:
            continue
        stripped = strip_strings(raw)
        opening = BLOCK_OPEN_RE.match(raw)

        if opening:
            stack.append({})
            labels.append(f"{opening.group(1)} {opening.group(2)}".strip())
            continue

        name_match = DIRECTIVE_RE.match(raw)
        if name_match and name_match.group(1) in SINGLE_INSTANCE:
            record_duplicate(
                stack[-1], labels[-1], name_match.group(1),
                f"{path}:{lineno}", problems,
            )

        # A bare `}` closes the innermost block. Braces are counted rather than
        # matched, so a line closing two blocks is handled too.
        for _ in range(stripped.count("}") - stripped.count("{")):
            if len(stack) > 1:
                stack.pop()
                labels.pop()

    return problems


def record_duplicate(counts, label, name, where, problems):
    first = counts.setdefault(name, None)
    if first is None:
        counts[name] = where
        return
    problems.append(
        f"`{name}` appears more than once in `{label}` (first at {first}, "
        f"again at {where}); nginx treats that as a fatal "
        f"[emerg] \"{name}\" directive is duplicate, so the edge container "
        f"crash-loops on start instead of serving"
    )


def strip_comments(text):
    """Remove nginx '#' comments, respecting quoted strings."""
    out = []
    for line in text.split("\n"):
        # A '#' inside quotes is literal; outside it starts a comment.
        in_s = in_d = False
        cut = len(line)
        for i, ch in enumerate(line):
            if ch == "\\":
                continue
            if ch == "'" and not in_d:
                in_s = not in_s
            elif ch == '"' and not in_s:
                in_d = not in_d
            elif ch == "#" and not in_s and not in_d:
                cut = i
                break
        out.append(line[:cut])
    return "\n".join(out)


def block_contexts(text):
    """Yield (line_number, depth) for each line, tracking brace depth.

    Depth 1 is the http block (inside nginx.conf), depth 2 a server block.
    """
    depth = 0
    for lineno, line in enumerate(text.split("\n"), 1):
        yield lineno, depth
        depth += line.count("{") - line.count("}")


def main(argv):
    root = pathlib.Path(argv[1] if len(argv) > 1 else DEFAULT_DIR)
    problems = []

    main_conf = root / "nginx.conf"
    confd = root / "conf.d"

    if not main_conf.is_file():
        print(f"::error::{main_conf} not found")
        return 1

    main_text = strip_comments(main_conf.read_text(encoding="utf-8"))

    # 1. No `set` (or other server-only directive) in the http context.
    for lineno, depth in block_contexts(main_text):
        line = main_text.split("\n")[lineno - 1]
        for directive in SERVER_ONLY:
            if re.search(rf"^\s*{directive}\s+\S", line):
                if depth == 1:
                    problems.append(
                        f"{main_conf}:{lineno}: `{directive}` is not allowed in the "
                        f"http context; move it into the server block that uses it "
                        f"(nginx aborts with [emerg] \"{directive}\" directive is "
                        f"not allowed here)"
                    )

    # 2. Every loaded .conf must be loadable without a certificate.
    loaded = sorted(p for p in confd.glob(f"*{LOADED_SUFFIX}"))
    included = sorted(p for p in confd.glob(f"*{INCLUDE_SUFFIX}"))
    for path in loaded:
        text = path.read_text(encoding="utf-8")
        body = strip_comments(text)
        for lineno, _ in block_contexts(body):
            line = body.split("\n")[lineno - 1]
            for cert in CERT_DIRECTIVES:
                if cert in line:
                    problems.append(
                        f"{path}:{lineno}: `{cert}` in a loaded .conf makes nginx "
                        f"refuse to start when the file is absent. Keep TLS in a "
                        f"separate file (tls.conf) that nginx only loads once a "
                        f"certificate exists."
                    )

    # 3. Every `set` in a loaded .conf must be inside a server block.
    #
    #    Files under conf.d/ are included from the http context, so their own
    #    top level is already inside http. Depth 1 within such a file is
    #    therefore a server block, and depth 0 is the http context itself --
    #    the same place that produced
    #      [emerg] "set" directive is not allowed here
    #    when the definitions were moved into nginx.conf.
    for path in included:
        body = strip_comments(path.read_text(encoding="utf-8"))
        raw = body.split("\n")
        for lineno, depth in block_contexts(body):
            line = raw[lineno - 1]
            if depth == 0 and re.search(r"^\s*set\s+\$", line):
                problems.append(
                    f"{path}:{lineno}: `set` is at the top level of an included "
                    f"file, which is the http context; move it into a server block "
                    f"(nginx aborts with [emerg] \"set\" directive is not allowed here)"
                )

    # 4. Every $var used in proxy_pass must be `set` SOMEWHERE. nginx resolves
    #    variables at request time and an undefined one is a runtime 502, not a
    #    start-up error, so nothing else would catch it.
    #
    #    The definitions live in the server blocks (proxy.conf, tls.conf), while
    #    the uses live in the shared route table, so "same file" is the wrong
    #    test -- the correct question is whether the name is defined anywhere in
    #    the configuration that will be loaded.
    defined_anywhere = set()
    for path in loaded + included:
        body = strip_comments(path.read_text(encoding="utf-8"))
        defined_anywhere |= set(re.findall(r"^\s*set\s+\$([a-z_]+)", body, re.M))

    for path in loaded + included:
        body = strip_comments(path.read_text(encoding="utf-8"))
        used = set(re.findall(r"proxy_pass\s+\$([a-z_]+)", body))
        for var in sorted(used - defined_anywhere):
            problems.append(
                f"{path}: `proxy_pass ${var}` is used but ${var} is never set "
                f"anywhere in the nginx config; nginx resolves variables at "
                f"request time, so this is a runtime 502 rather than a start-up "
                f"failure"
            )

    # 5. No single-instance directive may appear twice in one block, counting
    #    included files. This is the check that would have caught the
    #    proxy_http_version duplication that crash-looped the edge container.
    #    Only the files nginx actually loads need this: each is expanded fully
    #    (includes inlined) and then scanned block by block.
    for path in loaded:
        problems.extend(
            find_duplicate_directives(expand_includes(confd, path, problems))
        )

    for problem in problems:
        print(f"::error::{problem}")

    if problems:
        return 1

    print(
        f"  nginx config OK ({len(loaded)} loaded .conf + {len(included)} "
        f"included .inc, no cert dependency)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
