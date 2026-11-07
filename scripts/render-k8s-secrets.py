#!/usr/bin/env python3
"""Render Eve's Kubernetes secrets from an env file without printing a value.

Reads config/secrets.env and writes a v1 List of two Secrets on stdout, for
`kubectl apply -f -`:

  eve-app       keys every Eve service loads with envFrom
  eve-api-keys  signing and encryption keys that only the API reads. Only the
                API mounts it; GoTrue reads SUPABASE_JWT_SECRET from it by
                name. The worker, orchestrator, gateway, SSO and agent runtime
                (and the job code running beside them) never hold a key that
                could mint tokens or decrypt org secrets.

It replaces `kubectl create secret --from-env-file`, which reads one
KEY=VALUE per line and so cannot carry a multi-line PEM key.

Env file format (kubectl's --from-env-file format, plus quoted values):

  KEY=value     the rest of the line, verbatim, as kubectl reads it
  KEY="..."     double-quoted; may span lines; \\n, \\" and \\\\ are expanded
  KEY='...'     single-quoted; may span lines; taken literally
  KEY           read from this process's environment, as kubectl does
  # comment     ignored, as are blank lines

Error messages name the line and key, never the value.
"""

import argparse
import base64
import json
import os
import re
import sys

APP_SECRET = "eve-app"
API_SECRET = "eve-api-keys"

# Keys only the API reads (checked against apps/*/src and packages/*/src of
# eve-horizon); GoTrue also reads SUPABASE_JWT_SECRET, by name. Anything not
# listed here stays in eve-app.
API_ONLY_KEYS = frozenset({
    "EVE_SECRETS_MASTER_KEY",        # decrypts every org and project secret
    "EVE_AUTH_PRIVATE_KEY",          # signs user, job and service tokens
    "EVE_AUTH_JWT_SECRET",           # legacy HS256 token secret
    "EVE_REGISTRY_SIGNING_KEY",      # signs registry push and pull tokens
    "EVE_BOOTSTRAP_TOKEN",           # first-admin bootstrap
    "EVE_ORG_FS_LINK_TOKEN_SECRET",  # signs org filesystem link tokens
    "EVE_GITHUB_WEBHOOK_SECRET",     # verifies GitHub webhook signatures
    "SUPABASE_AUTH_SERVICE_KEY",     # GoTrue service-role (admin) token
    "SUPABASE_JWT_SECRET",           # HS256 secret; a token signed with it is
                                     # linked to any user by its email claim
})

ENV_NAME = re.compile(r"[-._a-zA-Z][-._a-zA-Z0-9]*\Z")
ESCAPES = {"n": "\n", '"': '"', "\\": "\\"}


class EnvFileError(ValueError):
    pass


def _line_of(text, index):
    return text.count("\n", 0, index) + 1


def _quoted(text, start, quote, key):
    """Return (value, index of the closing quote) for a value opened at start."""
    out = []
    i = start
    while i < len(text):
        ch = text[i]
        if ch == quote:
            return "".join(out), i
        if ch == "\\" and quote == '"' and i + 1 < len(text):
            nxt = text[i + 1]
            out.append(ESCAPES.get(nxt, "\\" + nxt))
            i += 2
            continue
        if ch == "\r" and text[i + 1:i + 2] == "\n":
            i += 1  # keep CRLF files from leaving \r inside a PEM
            continue
        out.append(ch)
        i += 1
    raise EnvFileError(f"line {_line_of(text, start)}: {key} has no closing {quote}")


def parse_env(text, environ=None):
    """Parse env-file text into an ordered dict of key to value."""
    environ = os.environ if environ is None else environ
    if text.startswith("﻿"):
        text = text[1:]
    values = {}
    pos = 0
    while pos < len(text):
        end = text.find("\n", pos)
        end = len(text) if end == -1 else end
        raw = text[pos:end].rstrip("\r")
        line_no = _line_of(text, pos)
        line = raw.lstrip()
        if not line or line.startswith("#"):
            pos = end + 1
            continue
        key, sep, rest = line.partition("=")
        if not ENV_NAME.fullmatch(key):
            raise EnvFileError(
                f"line {line_no}: expected KEY=VALUE. A multi-line value (such as a PEM key) "
                "must be wrapped in double quotes")
        if key in values:
            raise EnvFileError(f"line {line_no}: duplicate key {key}")
        if not sep:
            values[key] = environ.get(key, "")
        elif rest[:1] in ('"', "'"):
            start = pos + (len(raw) - len(line)) + len(key) + 2
            values[key], close = _quoted(text, start, rest[0], key)
            end = text.find("\n", close)
            end = len(text) if end == -1 else end
            if text[close + 1:end].strip():
                raise EnvFileError(
                    f"line {_line_of(text, close)}: unexpected text after the closing quote of {key}")
        elif rest.lstrip().startswith("-----BEGIN "):
            raise EnvFileError(
                f"line {line_no}: {key} starts a PEM key. Wrap the whole key in double quotes, "
                "either across lines or on one line with \\n escapes")
        else:
            values[key] = rest
        pos = end + 1
    for key, value in values.items():
        if value.lstrip().startswith("-----BEGIN ") and "\n" not in value:
            raise EnvFileError(f"{key} holds a PEM key without line breaks")
    return values


def split(values):
    app = {k: v for k, v in values.items() if k not in API_ONLY_KEYS}
    api = {k: v for k, v in values.items() if k in API_ONLY_KEYS}
    return app, api


def secret(name, namespace, data):
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "type": "Opaque",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": {"app.kubernetes.io/managed-by": "eve-infra"},
        },
        "data": {k: base64.b64encode(v.encode()).decode() for k, v in sorted(data.items())},
    }


def render(values, namespace):
    app, api = split(values)
    return {
        "apiVersion": "v1",
        "kind": "List",
        "items": [secret(APP_SECRET, namespace, app), secret(API_SECRET, namespace, api)],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("env_file")
    parser.add_argument("--namespace", default="eve")
    args = parser.parse_args(argv)
    if sys.stdout.isatty():
        print("render-k8s-secrets: refusing to write secret values to a terminal; "
              "pipe the output into `kubectl apply -f -`", file=sys.stderr)
        return 1
    try:
        with open(args.env_file, encoding="utf-8") as handle:
            values = parse_env(handle.read())
    except (OSError, UnicodeDecodeError, EnvFileError) as exc:
        print(f"render-k8s-secrets: {args.env_file}: {exc}", file=sys.stderr)
        return 1
    app, api = split(values)
    json.dump(render(values, args.namespace), sys.stdout)
    sys.stdout.write("\n")
    print(f"render-k8s-secrets: {APP_SECRET}: {len(app)} keys; "
          f"{API_SECRET}: {', '.join(sorted(api)) or 'no keys'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
