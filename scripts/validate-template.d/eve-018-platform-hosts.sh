# shellcheck shell=bash
# shellcheck disable=SC2154 # fail, REPO_ROOT and work_root come from validate-template.sh
# EVE-018: GCP DNS publishes named platform hosts plus *.apps.<domain> (no
# apex or *.<domain> wildcard by default), and the GKE overlay refuses tenant
# ingresses on platform hosts. The domains in the policy, the worker and API
# EVE_DEFAULT_DOMAIN, the API ingress host and the DNS records must agree.

dns_module="$REPO_ROOT/terraform/gcp/modules/dns"

# Print the default list of a Terraform list(string) variable, one per line.
tf_list_default() {
  awk -v var="$1" '
    $0 ~ "^variable \"" var "\"" { v = 1 }
    v && /^  default += \[/ { line = $0; sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
      n = split(line, items, ","); for (i = 1; i <= n; i++) { gsub(/[ "]/, "", items[i]); print items[i] }
      exit }
    v && /^}/ { v = 0 }
  ' "$2"
}

# Apex and *.<domain> records may exist only behind legacy_wildcard_records.
if awk '
  /^resource "google_dns_record_set"/ { block = ""; inres = 1 }
  inres { block = block $0 "\n" }
  inres && /^}/ {
    inres = 0
    if (block ~ /name += "(\*\.)?\$\{var\.domain\}\."/ && block !~ /count += var\.legacy_wildcard_records \? 1 : 0/) bad = 1
  }
  END { exit !bad }' "$dns_module/main.tf"; then
  fail "GCP DNS module publishes an apex or *.<domain> record outside legacy_wildcard_records"
fi
# shellcheck disable=SC2016 # a literal Terraform interpolation
grep -Fq 'name         = "*.apps.${var.domain}."' "$dns_module/main.tf" \
  || fail "GCP DNS module must publish the *.apps.<domain> app wildcard"
for vars_file in "$dns_module/variables.tf" "$REPO_ROOT/terraform/gcp/variables.tf"; do
  awk '/^variable "(dns_)?legacy_wildcard_records"/ { v = 1 } v && /default += false/ { ok = 1 }
    v && /^}/ { v = 0 } END { exit !ok }' "$vars_file" \
    || fail "legacy wildcard DNS records must default to off ($vars_file)"
done
module_hosts="$(tf_list_default platform_hosts "$dns_module/variables.tf")"
[[ -n "$module_hosts" ]] || fail "GCP DNS module has no default platform_hosts"
[[ "$(tf_list_default dns_platform_hosts "$REPO_ROOT/terraform/gcp/variables.tf")" == "$module_hosts" ]] \
  || fail "terraform/gcp dns_platform_hosts default differs from the DNS module's platform_hosts"

gcp_render="$work_root/gcp.yaml"

policy="$(rendered_doc ValidatingAdmissionPolicy eve-ingress-host-guard "$gcp_render")"
[[ -n "$policy" ]] || fail "gcp render is missing the eve-ingress-host-guard admission policy"
grep -Fxq '  failurePolicy: Fail' <<<"$policy" || fail "eve-ingress-host-guard must fail closed"
binding="$(rendered_doc ValidatingAdmissionPolicyBinding eve-ingress-host-guard "$gcp_render")"
grep -A1 -Fx '  validationActions:' <<<"$binding" | grep -Fxq '  - Deny' \
  || fail "eve-ingress-host-guard binding must deny"
grep -Fq "'eve.env_id' in namespaceObject.metadata.labels" <<<"$policy" \
  || fail "eve-ingress-host-guard must cover environment namespaces"

policy_var() {
  awk -v name="$1" '
    /^  - expression: / { value = $0; sub(/^  - expression: '"'''"'/, "", value); sub(/'"'''"'$/, "", value) }
    $0 == "    name: " name { print value; exit }
  ' <<<"$policy"
}
platform_domain="$(policy_var platformDomain)"
app_domain="$(policy_var appDomain)"
[[ -n "$platform_domain" && -n "$app_domain" ]] || fail "eve-ingress-host-guard must define platformDomain and appDomain"
[[ "$app_domain" == "apps.$platform_domain" ]] \
  || fail "eve-ingress-host-guard appDomain must be apps.<platform domain> (the DNS app wildcard)"

for deployment in eve-worker eve-api; do
  [[ "$(env_value EVE_DEFAULT_DOMAIN < <(rendered_doc Deployment "$deployment" "$gcp_render"))" == "$app_domain" ]] \
    || fail "gcp $deployment EVE_DEFAULT_DOMAIN must equal the policy appDomain ($app_domain)"
done

api_host="$(rendered_doc Ingress eve-api "$gcp_render" | awk '/^ *(- )?host: / { print $NF; exit }')"
[[ "$api_host" == "api.$platform_domain" ]] \
  || fail "gcp eve-api ingress host ($api_host) must be api.<platform domain> ($platform_domain)"

# Every platform ingress host (rules and TLS) must sit under the platform
# domain and have a DNS record. A platform host outside it (for example
# sso.example.com beside eve.example.com) is not reserved by the host guard,
# so a tenant could register it as a custom domain and capture its paths.
platform_ingress_hosts="$(awk '
  /^---$/ { ingress = 0 }
  /^kind: Ingress$/ { ingress = 1 }
  !ingress { next }
  /^ *(- )?host: / { print $NF; next }
  /^  - hosts:$/ { tls = 1; next }
  tls && /^    - / { print $2; next }
  { tls = 0 }' "$gcp_render" | sort -u)"
[[ -n "$platform_ingress_hosts" ]] || fail "gcp render has no platform ingress hosts"
for host in $platform_ingress_hosts; do
  [[ "$host" == "$platform_domain" || "$host" == *".$platform_domain" ]] \
    || fail "gcp platform ingress host $host is outside the platform domain $platform_domain"
  label="${host%".$platform_domain"}"
  grep -Fxq "$label" <<<"$module_hosts" \
    || fail "gcp ingress host $host has no DNS record (add \"$label\" to platform_hosts)"
done

# Auth and SSO URLs must name hosts the platform ingress serves, and the SSO
# session cookie must cover sso.<domain> and the app hosts: the platform domain.
for pair in "eve-sso SUPABASE_AUTH_EXTERNAL_URL" "supabase-auth API_EXTERNAL_URL" "supabase-auth GOTRUE_SITE_URL"; do
  read -r deployment var <<<"$pair"
  url="$(env_value "$var" < <(rendered_doc Deployment "$deployment" "$gcp_render"))"
  url_host="${url#https://}"
  url_host="${url_host%%/*}"
  grep -Fxq "$url_host" <<<"$platform_ingress_hosts" \
    || fail "gcp $deployment $var ($url) must point at a platform ingress host"
done
[[ "$(env_value EVE_DEFAULT_DOMAIN < <(rendered_doc Deployment eve-sso "$gcp_render"))" == "$platform_domain" ]] \
  || fail "gcp eve-sso EVE_DEFAULT_DOMAIN (its session cookie domain) must be the platform domain"
