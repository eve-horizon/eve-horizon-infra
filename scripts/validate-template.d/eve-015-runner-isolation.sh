# shellcheck shell=bash
# shellcheck disable=SC2154 # fail, OVERLAYS and work_root come from validate-template.sh
# EVE-015: runner pods run job code under a token-less service account, the
# worker's RBAC carries no rights its code never uses, and the GKE overlay
# guards Eve's controller identities with admission policies.

# Print every RBAC rule block of a Role/ClusterRole document (stdin) that
# lists resource $1.
rbac_rules_for() {
  awk -v res="$1" '
    function flush() { if (hit) printf "%s", blk; blk = ""; hit = 0 }
    /^- apiGroups:/ { flush() }
    /^[a-z]/ { flush(); next }
    { blk = blk $0 "\n" }
    $0 == "  - " res { hit = 1 }
    END { flush() }
  '
}

for overlay in "${OVERLAYS[@]}"; do
  rendered="$work_root/${overlay}.yaml"

  runner_sa="$(rendered_doc ServiceAccount eve-runner "$rendered")"
  [[ -n "$runner_sa" ]] || fail "$overlay render is missing the eve-runner service account"
  grep -Fxq 'automountServiceAccountToken: false' <<<"$runner_sa" \
    || fail "$overlay eve-runner service account must not mount a token"
  if grep -Eq '^  annotations:' <<<"$runner_sa"; then
    fail "$overlay eve-runner service account must carry no cloud identity annotations"
  fi
  if awk '/^kind: (Cluster)?RoleBinding$/ { binding = 1 } /^---$/ { binding = 0 }
      binding && /^  name: eve-runner$/ { found = 1 } END { exit !found }' "$rendered"; then
    fail "$overlay binds a role to eve-runner; runner pods need no Kubernetes API access"
  fi

  worker="$(rendered_doc Deployment eve-worker "$rendered")"
  [[ "$(env_value EVE_RUNNER_SERVICE_ACCOUNT <<<"$worker")" == "eve-runner" ]] \
    || fail "$overlay worker must launch runner pods as eve-runner"

  worker_rbac="$(rendered_doc Role eve-worker "$rendered")$(rendered_doc ClusterRole eve-worker "$rendered")"
  [[ -n "$worker_rbac" ]] || fail "$overlay render is missing the eve-worker roles"
  if grep -Ex '  - (watch|pods/exec|pods/status|daemonsets|statefulsets|replicasets|cronjobs)' <<<"$worker_rbac"; then
    fail "$overlay eve-worker RBAC grants a verb or resource the worker never uses"
  fi
  if rbac_rules_for secrets <<<"$worker_rbac" | grep -Fx '  - list'; then
    fail "$overlay eve-worker may not list Secrets"
  fi
done

gcp_render="$work_root/gcp.yaml"
for policy in eve-controller-workload-guard eve-controller-scope-guard eve-controller-platform-namespace-guard; do
  vap="$(rendered_doc ValidatingAdmissionPolicy "$policy" "$gcp_render")"
  [[ -n "$vap" ]] || fail "gcp render is missing admission policy $policy"
  grep -Fxq '  failurePolicy: Fail' <<<"$vap" || fail "$policy must fail closed"
  for identity in eve-worker eve-orchestrator eve-runner; do
    grep -Fq "'system:serviceaccount:eve:${identity}'" <<<"$vap" \
      || fail "$policy does not cover the $identity service account"
  done
  binding="$(rendered_doc ValidatingAdmissionPolicyBinding "$policy" "$gcp_render")"
  grep -Fxq "  policyName: $policy" <<<"$binding" || fail "gcp render is missing the $policy binding"
  grep -A1 -Fx '  validationActions:' <<<"$binding" | grep -Fxq '  - Deny' \
    || fail "$policy binding must deny, not only warn or audit"
done

# The guards refuse hostNetwork pods and non-ClusterIP Services. Keep the GKE
# worker on settings that render neither (stable egress and TCP ingress off).
gcp_worker="$(rendered_doc Deployment eve-worker "$gcp_render")"
[[ "$(env_value EVE_COMPUTE_MODEL <<<"$gcp_worker")" == "gke" ]] \
  || fail "gcp worker must keep EVE_COMPUTE_MODEL=gke (stable egress pods would be refused)"
case "$(env_value EVE_TCP_INGRESS_PROVIDER <<<"$gcp_worker")" in
  "" | none) ;;
  *) fail "gcp worker enables TCP ingress LoadBalancer Services, which the admission guard refuses" ;;
esac

# Service external IPs (CVE-2020-8554) are refused like non-ClusterIP types.
grep -Fq 'has(object.spec.externalIPs)' <<<"$(rendered_doc ValidatingAdmissionPolicy eve-controller-scope-guard "$gcp_render")" \
  || fail "eve-controller-scope-guard must refuse Service externalIPs"

# In eve, controllers may only manage runner pods and workspace claims. The
# names the guard allows must be the ones the platform and render use.
ns_guard="$(rendered_doc ValidatingAdmissionPolicy eve-controller-platform-namespace-guard "$gcp_render")"
ns_guard_flat="$(tr -d '\n' <<<"$ns_guard" | tr -s ' ')"
grep -A2 -Fx '    namespaceSelector:' <<<"$ns_guard" | grep -Fxq '        kubernetes.io/metadata.name: eve' \
  || fail "eve-controller-platform-namespace-guard must select the eve namespace"
grep -Fxq "      - '*/*'" <<<"$ns_guard" \
  || fail "eve-controller-platform-namespace-guard must also cover subresources"
for fragment in "labels['eve.type'] == 'runner'" "startsWith('eve-runner-')" "startsWith('eve-ws-')" \
  "serviceAccountName == 'eve-runner'"; do
  grep -Fq "$fragment" <<<"$ns_guard_flat" \
    || fail "eve-controller-platform-namespace-guard lost its runner rule ($fragment)"
done
org_claim="$(grep -Eo "claimName == '[a-z0-9-]+'" <<<"$ns_guard_flat" | head -1 | cut -d"'" -f2)"
[[ -n "$(rendered_doc PersistentVolumeClaim "$org_claim" "$gcp_render")" ]] \
  || fail "eve-controller-platform-namespace-guard allows org claim '$org_claim', which the gcp render does not define"
[[ "$(env_value EVE_K8S_NAMESPACE <<<"$gcp_worker")" == "eve" ]] \
  || fail "gcp worker must launch runner pods in eve, where the namespace guard expects them"
if [[ "$(env_value EVE_BUILD_BACKEND <<<"$gcp_worker")" == "kaniko" ]]; then
  fail "gcp worker uses the kaniko build backend, which writes Secrets and Jobs in eve that the guard refuses"
fi
