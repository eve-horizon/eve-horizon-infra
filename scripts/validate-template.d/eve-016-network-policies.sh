# shellcheck shell=bash
# shellcheck disable=SC2154 # fail, REPO_ROOT and work_root come from validate-template.sh
# EVE-016: the GKE overlay restricts ingress to the unauthenticated internal
# services, and the GKE module creates clusters that enforce NetworkPolicy
# without ever replacing an existing cluster to do so.

gcp_render="$work_root/gcp.yaml"

# policy name, selected pods (label), allowed callers (app.kubernetes.io/name)
expected_policies=(
  "eve-worker-ingress|app.kubernetes.io/name: eve-worker|eve-api eve-orchestrator"
  "eve-agent-runtime-ingress|app.kubernetes.io/name: eve-agent-runtime|eve-orchestrator eve-api eve-worker"
  "eve-orchestrator-ingress|app.kubernetes.io/name: eve-orchestrator|eve-api eve-worker"
  "eve-runner-ingress|eve.type: runner|eve-worker eve-agent-runtime"
  "mailpit-ingress|app.kubernetes.io/name: mailpit|eve-api supabase-auth"
)

for entry in "${expected_policies[@]}"; do
  IFS='|' read -r policy selector callers <<<"$entry"
  netpol="$(rendered_doc NetworkPolicy "$policy" "$gcp_render")"
  [[ -n "$netpol" ]] || fail "gcp render is missing NetworkPolicy $policy"
  grep -A2 -Fx '  podSelector:' <<<"$netpol" | grep -Fxq "      $selector" \
    || fail "$policy must select pods labelled '$selector'"
  grep -A1 -Fx '  policyTypes:' <<<"$netpol" | grep -Fxq '  - Ingress' \
    || fail "$policy must restrict ingress"
  for caller in $callers; do
    grep -Fxq "          app.kubernetes.io/name: $caller" <<<"$netpol" \
      || fail "$policy must admit $caller"
  done
  # Exactly the callers above: no namespaceSelector, ipBlock or extra pods.
  if grep -Eq '^ +- (namespaceSelector|ipBlock):' <<<"$netpol"; then
    fail "$policy admits traffic from outside the eve namespace"
  fi
  [[ "$(grep -c '^          app.kubernetes.io/name: ' <<<"$netpol")" == "$(wc -w <<<"$callers" | tr -d ' ')" ]] \
    || fail "$policy admits callers beyond: $callers"
done

# Every app.kubernetes.io/name a NetworkPolicy names (as target or caller)
# must label the pods of a rendered Deployment or StatefulSet, or the policy
# silently selects nothing (target) or cuts a platform caller (source).
workload_labels="$(awk '
  /^---$/ { workload = 0 }
  /^kind: (Deployment|StatefulSet)$/ { workload = 1 }
  workload && /^        app\.kubernetes\.io\/name: / { print $2 }
' "$gcp_render" | sort -u)"
policy_labels="$(awk '
  /^---$/ { netpol = 0 }
  /^kind: NetworkPolicy$/ { netpol = 1 }
  netpol && /^ +app\.kubernetes\.io\/name: / { print $2 }
' "$gcp_render" | sort -u)"
for label in $policy_labels; do
  grep -Fxq "$label" <<<"$workload_labels" \
    || fail "a gcp NetworkPolicy refers to pods labelled $label, but no workload carries that label"
done

# Dataplane V2: on for new clusters, never a reason to replace an old one.
gke_module="$REPO_ROOT/terraform/gcp/modules/gke/main.tf"
grep -Eq '^  datapath_provider += var\.enable_dataplane_v2 \? "ADVANCED_DATAPATH" : null$' "$gke_module" \
  || fail "GKE module must set datapath_provider from enable_dataplane_v2"
grep -Eq '^    ignore_changes += \[.*\bdatapath_provider\b.*\]$' "$gke_module" \
  || fail "GKE module must ignore datapath_provider changes so existing clusters are never replaced"
awk '/^variable "enable_dataplane_v2"/ { v = 1 } v && /default += true/ { found = 1 } v && /^}/ { v = 0 }
  END { exit !found }' "$REPO_ROOT/terraform/gcp/modules/gke/variables.tf" \
  || fail "new GKE clusters must default to Dataplane V2"
