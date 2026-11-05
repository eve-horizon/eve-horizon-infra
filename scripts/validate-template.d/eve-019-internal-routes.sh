# shellcheck shell=bash
# shellcheck disable=SC2154 # fail, OVERLAYS and work_root come from validate-template.sh
# EVE-019: every overlay that publishes the API also publishes an Ingress that
# sends /internal/* to a Service with no endpoints, except the registry token
# endpoint (the registry's token realm), on the same host and ingress class.

# Print "path pathType service port" for each path of an Ingress (stdin).
ingress_paths() {
  awk '
    function flush() { if (path != "") print path, type, svc, port; path = type = svc = port = "" }
    /^      - backend:$/ { flush() }
    /^            name: / { svc = $2 }
    /^              number: / { port = $2 }
    /^        path: / { path = $2 }
    /^        pathType: / { type = $2 }
    END { flush() }
  '
}

# The class an ingress controller sees: spec.ingressClassName, else the
# legacy kubernetes.io/ingress.class annotation.
ingress_class() {
  awk '
    /^  ingressClassName: / { cls = $2 }
    /^    kubernetes\.io\/ingress\.class: / { ann = $2 }
    END { print (cls != "" ? cls : ann) }
  '
}

ingress_tls() {
  awk '/^  tls:$/ { t = 1; next } t && /^[^ ]|^  [a-z]/ { t = 0 } t' | tr -d ' -' | sort
}

for overlay in "${OVERLAYS[@]}"; do
  rendered="$work_root/${overlay}.yaml"
  api_ingress="$(rendered_doc Ingress eve-api "$rendered")"
  [[ -n "$api_ingress" ]] || continue

  api_host="$(awk '/^ *(- )?host: / { print $NF; exit }' <<<"$api_ingress")"
  block="$(rendered_doc Ingress eve-api-internal "$rendered")"
  [[ -n "$block" ]] || fail "$overlay publishes the API but not the eve-api-internal block Ingress"

  [[ "$(awk '/^ *(- )?host: / { print $NF }' <<<"$block" | sort -u)" == "$api_host" ]] \
    || fail "$overlay eve-api-internal must serve exactly the API host ($api_host)"
  [[ "$(ingress_class <<<"$block")" == "$(ingress_class <<<"$api_ingress")" ]] \
    || fail "$overlay eve-api-internal must use the eve-api ingress class"
  [[ "$(ingress_tls <<<"$block")" == "$(ingress_tls <<<"$api_ingress")" ]] \
    || fail "$overlay eve-api-internal TLS must match eve-api"
  if grep -Eq '^    cert-manager\.io/' <<<"$block"; then
    fail "$overlay eve-api-internal must not ask cert-manager for a second certificate"
  fi

  paths="$(ingress_paths <<<"$block")"
  grep -Fxq '/internal/registry/token Exact eve-api 4701' <<<"$paths" \
    || fail "$overlay eve-api-internal must keep /internal/registry/token (Exact) on eve-api"
  blackhole="$(awk '$1 == "/internal" && $2 == "Prefix" { print $3 }' <<<"$paths")"
  [[ -n "$blackhole" && "$blackhole" != "eve-api" ]] \
    || fail "$overlay eve-api-internal must route the /internal prefix away from eve-api"
  [[ "$(wc -l <<<"$paths" | tr -d ' ')" == "2" ]] \
    || fail "$overlay eve-api-internal may only carry the token path and the /internal block"

  # The block Service must exist and select no workload's pods.
  service="$(rendered_doc Service "$blackhole" "$rendered")"
  [[ -n "$service" ]] || fail "$overlay is missing the $blackhole Service"
  selector="$(awk '/^  selector:$/ { s = 1; next } s && /^    / { sub(/^ +/, ""); print; next } { s = 0 }' <<<"$service")"
  [[ -n "$selector" ]] || fail "$overlay $blackhole must select pods by a label that no workload carries"
  while IFS= read -r label; do
    if awk -v label="$label" '
      /^---$/ { w = 0 } /^kind: (Deployment|StatefulSet|DaemonSet|Job|Pod)$/ { w = 1 }
      w { line = $0; sub(/^ +/, "", line); if (line == label) found = 1 }
      END { exit !found }' "$rendered"; then
      fail "$overlay $blackhole selects real pods ($label); it must have no endpoints"
    fi
  done <<<"$selector"

  # The registry token realm, where a registry is rendered, is the kept path.
  if realm="$(grep -Eo 'realm: [^ ]+' "$rendered")"; then
    while read -r _ url; do
      [[ "$url" == "https://$api_host/internal/registry/token" ]] \
        || fail "$overlay registry token realm ($url) is not the API host's kept token path"
    done <<<"$realm"
  fi

  # The dashboard proxies /api/* to the API (Express mount, case-insensitive),
  # so its host must block every letter-case spelling of /api/internal.
  dashboard_ingress="$(rendered_doc Ingress eve-dashboard "$rendered")"
  [[ -n "$dashboard_ingress" ]] || continue
  dashboard_host="$(awk '/^ *(- )?host: / { print $NF; exit }' <<<"$dashboard_ingress")"
  dashboard_block="$(rendered_doc Ingress eve-dashboard-internal "$rendered")"
  [[ -n "$dashboard_block" ]] \
    || fail "$overlay publishes the dashboard (an API proxy) but not the eve-dashboard-internal block"
  [[ "$(awk '/^ *(- )?host: / { print $NF }' <<<"$dashboard_block" | sort -u)" == "$dashboard_host" ]] \
    || fail "$overlay eve-dashboard-internal must serve exactly the dashboard host ($dashboard_host)"
  [[ "$(ingress_class <<<"$dashboard_block")" == "$(ingress_class <<<"$dashboard_ingress")" ]] \
    || fail "$overlay eve-dashboard-internal must use the eve-dashboard ingress class"
  [[ "$(ingress_tls <<<"$dashboard_block")" == "$(ingress_tls <<<"$dashboard_ingress")" ]] \
    || fail "$overlay eve-dashboard-internal TLS must match eve-dashboard"
  dashboard_paths="$(ingress_paths <<<"$dashboard_block")"
  for a in a A; do for p in p P; do for i in i I; do
    grep -Fxq "/${a}${p}${i}/internal Prefix $blackhole 80" <<<"$dashboard_paths" \
      || fail "$overlay eve-dashboard-internal must send /${a}${p}${i}/internal to $blackhole"
  done; done; done
  [[ "$(wc -l <<<"$dashboard_paths" | tr -d ' ')" == "8" ]] \
    || fail "$overlay eve-dashboard-internal may only carry the eight /api/internal blocks"
done

for overlay in "${OVERLAYS[@]}"; do
  [[ -n "$(rendered_doc Ingress eve-api "$work_root/${overlay}.yaml")" ]] && continue
  fail "$overlay renders no eve-api Ingress; the /internal block check did not run"
done
