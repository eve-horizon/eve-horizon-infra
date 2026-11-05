# shellcheck shell=bash
# shellcheck disable=SC2154 # fail and work_root come from validate-template.sh
# Assertions that tie two changes together. Each change's own check rendered
# without the other, so none of them could make these.

gcp_render="$work_root/gcp.yaml"

# Print "<policy>: k=v k=v" for each NetworkPolicy's podSelector, with
# " EXPR" when it also uses matchExpressions. An empty selector prints no
# pairs: it selects every pod in the namespace.
netpol_selectors() {
  # shellcheck disable=SC2016 # a Go template, not shell
  render_query "$1" '{{if eq .kind "NetworkPolicy"}}{{.metadata.name}}:{{range $k, $v := .spec.podSelector.matchLabels}} {{$k}}={{$v}}{{end}}{{if .spec.podSelector.matchExpressions}} EXPR{{end}}{{"\n"}}{{end}}'
}

# Print the pod template labels of a workload as k=v lines.
pod_labels() {
  render_query "$1" "{{if and (eq .kind \"$2\") (eq .metadata.name \"$3\")}}{{range \$k, \$v := .spec.template.metadata.labels}}{{\$k}}={{\$v}}{{\"\\n\"}}{{end}}{{end}}"
}

# EVE-016 x EVE-002/003: GCP keeps the Eve-native registry, and pushes,
# kubelet pulls and the token realm all arrive through the ingress controller.
# The NetworkPolicies admit only named in-namespace callers, so none may
# select the registry pods, and none may select every pod (a default deny
# would cut the registry, the API and every other public service).
registry_labels="$(pod_labels "$gcp_render" Deployment eve-registry)"
[[ -n "$registry_labels" ]] || fail "gcp render has no eve-registry pod labels to check"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  policy="${line%%:*}"
  read -ra pairs <<<"${line#*:}"
  [[ ${#pairs[@]} -gt 0 ]] \
    || fail "gcp NetworkPolicy $policy selects every pod in the namespace, including the registry"
  [[ " ${pairs[*]} " != *" EXPR "* ]] \
    || fail "gcp NetworkPolicy $policy uses matchExpressions; check by hand that it leaves eve-registry alone"
  selects_registry=1
  for pair in "${pairs[@]}"; do
    grep -Fxq "$pair" <<<"$registry_labels" || selects_registry=0
  done
  ((selects_registry == 0)) \
    || fail "gcp NetworkPolicy $policy selects the registry pods; pushes and pulls come through the ingress controller"
done < <(netpol_selectors "$gcp_render")

# EVE-014/037 x EVE-016: the pods the agent-runtime NetworkPolicy fences are
# the ones that run as eve-agent-runtime, the KSA bound to the read-only
# agents GSA (not the platform storage GSA).
runtime_policy_selector="$(netpol_selectors "$gcp_render" | sed -n 's/^eve-agent-runtime-ingress: //p')"
[[ -n "$runtime_policy_selector" ]] || fail "gcp render has no eve-agent-runtime-ingress selector"
runtime_labels="$(pod_labels "$gcp_render" StatefulSet eve-agent-runtime)"
for pair in $runtime_policy_selector; do
  grep -Fxq "$pair" <<<"$runtime_labels" \
    || fail "eve-agent-runtime-ingress selects $pair, which the agent runtime pods do not carry"
done
render_query "$gcp_render" '{{if and (eq .kind "StatefulSet") (eq .metadata.name "eve-agent-runtime")}}{{.spec.template.spec.serviceAccountName}}{{end}}' \
  | grep -Fxq eve-agent-runtime \
  || fail "gcp agent runtime pods must run as the eve-agent-runtime KSA (its own read-only GSA)"
