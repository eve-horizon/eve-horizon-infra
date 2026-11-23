# shellcheck shell=bash
# shellcheck disable=SC2154 # fail, REPO_ROOT, OVERLAYS and work_root come from validate-template.sh
# Eve releases publish only to GHCR (ghcr.io/eve-horizon/eve-horizon), signed
# and versioned. The template pulls from there by default, pins versions
# rather than floating tags, and `eve-infra version` can list GHCR's tags.

readonly GHCR_REGISTRY="ghcr.io/eve-horizon/eve-horizon"

[[ "$(awk '/^platform:/ { p = 1 } p && /^  registry:/ { gsub(/"/, "", $2); print $2; exit }' "$REPO_ROOT/config/platform.yaml")" == "$GHCR_REGISTRY" ]] \
  || fail "config/platform.yaml platform.registry must default to $GHCR_REGISTRY"

if git -C "$REPO_ROOT" grep -n -E 'public\.ecr\.aws/w7c4v0w3|gallery\.ecr\.aws/w7c4v0w3' \
  -- . ':(exclude)CHANGELOG.md' ':(exclude)scripts/validate-template.d/ghcr-registry.sh'; then
  fail "the template still points at the retired ECR registry"
fi

for overlay in "${OVERLAYS[@]}"; do
  render="$work_root/$overlay.yaml"
  if grep -Eq "image: ${GHCR_REGISTRY}/[a-z-]+:(latest|staging)$" "$render"; then
    fail "$overlay renders a floating platform image tag"
  fi
  # Not every overlay sets toolchain images (aws-eks does not).
  prefixes="$(awk '/- name: EVE_TOOLCHAIN_IMAGE_PREFIX$/ { getline; gsub(/"/, "", $2); print $2 }' "$render" | sort -u)"
  tags="$(awk '/- name: EVE_TOOLCHAIN_IMAGE_TAG$/ { getline; gsub(/"/, "", $2); print $2 }' "$render" | sort -u)"
  if [[ -n "$prefixes" ]]; then
    [[ "$prefixes" == "${GHCR_REGISTRY}/toolchain-" ]] || fail "$overlay toolchain prefix is not GHCR: $prefixes"
    [[ "$tags" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$overlay toolchain tag is not a pinned version: $tags"
  fi
done

# `eve-infra version` against a stub GHCR: anonymous token, then the tag list.
ghcr_root="$work_root/ghcr-version"
mkdir -p "$ghcr_root/stub"
cp -R "$REPO_ROOT/bin" "$REPO_ROOT/config" "$ghcr_root/"
cat >"$ghcr_root/stub/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GHCR_CURL_LOG"
case "$*" in
  *"https://ghcr.io/token?service=ghcr.io&scope=repository:eve-horizon/eve-horizon/api:pull"*) echo '{"token":"anonymous"}' ;;
  *"Authorization: Bearer anonymous"*"https://ghcr.io/v2/eve-horizon/eve-horizon/api/tags/list"*)
    echo '{"name":"eve-horizon/eve-horizon/api","tags":["0.1.331","0.1.400","sha256-abc.sig","0.1.99"]}' ;;
  *) echo "stub curl: unexpected: $*" >&2; exit 7 ;;
esac
STUB
chmod +x "$ghcr_root/stub/curl"
: >"$ghcr_root/curl.log"
ghcr_output="$(PATH="$ghcr_root/stub:$PATH" GHCR_CURL_LOG="$ghcr_root/curl.log" "$ghcr_root/bin/eve-infra" version 2>&1)" \
  || fail "eve-infra version failed against GHCR: $ghcr_output"
grep -Fq "0.1.400" <<<"$ghcr_output" \
  || fail "eve-infra version did not read the latest GHCR tag: $ghcr_output"
