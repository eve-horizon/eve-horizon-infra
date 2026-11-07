#!/usr/bin/env bash
# =============================================================================
# Refuse rendered manifests that still carry the template's placeholder values
# =============================================================================
#
# The overlays ship with placeholders (INSTANCE_PREFIX, GCP_PROJECT,
# YOUR_REGION, REPLACE_*, example.com hosts) that each instance fills in by
# hand. Deploying one unfilled points Workload Identity, buckets, ingress
# hosts or TLS at values that do not exist, so fail first and say where.
#
# Usage:
#   kubectl kustomize k8s/overlays/<overlay> | scripts/check-placeholders.sh
#   scripts/check-placeholders.sh rendered.yaml
#
# EVE_ALLOW_PLACEHOLDERS=1 reports them as a warning and exits 0.
# =============================================================================
set -euo pipefail

# No backslashes: awk -v processes escapes, and GNU awk turns "\." into ".".
readonly PLACEHOLDERS='INSTANCE_PREFIX|GCP_PROJECT|YOUR_REGION|REPLACE_[A-Z0-9_]+|[A-Za-z0-9*.-]*example[.](com|net|org)'

# Host-like tokens only: the pattern stops at "@", ":" and "/", so a
# credential in a URL never reaches the output.
# Print "<placeholder>: <Kind>/<name>, ..." for each placeholder found. Kind
# and name are collected per document because kustomize sorts `data` ahead of
# `kind` and `metadata`.
found="$(awk -v pattern="$PLACEHOLDERS" '
  function flush(  token) {
    for (token in doc) where[token] = where[token] (where[token] == "" ? "" : ", ") kind "/" name
    split("", doc); kind = ""; name = ""; meta = 0
  }
  /^---$/ { flush(); next }
  /^kind: / { kind = $2 }
  /^metadata:/ { meta = 1 }
  /^[^ ]/ && !/^metadata:/ { meta = 0 }
  meta && /^  name: / { name = $2 }
  {
    line = $0
    while (match(line, pattern)) {
      doc[substr(line, RSTART, RLENGTH)] = 1
      line = substr(line, RSTART + RLENGTH)
    }
  }
  END { flush(); for (token in where) print "  " token ": " where[token] }
' "${1:--}" | sort)"

[[ -z "$found" ]] && exit 0

if [[ "${EVE_ALLOW_PLACEHOLDERS:-0}" == "1" ]]; then
  echo "Warning: rendered manifests still contain template placeholders (EVE_ALLOW_PLACEHOLDERS=1):" >&2
  echo "$found" >&2
  exit 0
fi

echo "Error: rendered manifests still contain template placeholders:" >&2
echo "$found" >&2
echo "Fill these in the overlay (and config/platform.yaml) for this instance before deploying." >&2
echo "To deploy anyway, set EVE_ALLOW_PLACEHOLDERS=1." >&2
exit 1
