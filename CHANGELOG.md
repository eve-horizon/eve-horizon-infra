# Changelog

All notable changes to the `eve-horizon-infra` template.

Downstream repos: consult this during `upstream-sync` operations.
Each entry includes **Sync impact** to guide what downstream agents need to do.

---

## [2026-11-05]

### fix: run the API in production mode

- **Scope:** `k8s/base/api-deployment.yaml`,
  `k8s/overlays/aws/api-deployment-patch.yaml`, `scripts/validate-template.sh`
- **Sync impact:**
  - `k8s/base/api-deployment.yaml` — auto-sync safe; sets `NODE_ENV=production`
    on `eve-api`. Platform images up to 0.1.321 set no `NODE_ENV`, so the API
    ran in development mode, where a completed first-admin bootstrap re-issued
    the admin's token to any caller. In production mode bootstrap requires
    `EVE_BOOTSTRAP_TOKEN` and is closed once an admin exists.
  - `k8s/overlays/*/api-deployment-patch.yaml` — **action required** for any
    instance overlay whose API patch replaces the env list (`$patch: replace`):
    add `NODE_ENV=production` there too, or the base value is dropped. Verify
    with `kubectl kustomize k8s/overlays/<overlay>` and roll the API.
  - `scripts/validate-template.sh` — template-only CI assertion that every
    overlay renders `NODE_ENV=production` on `eve-api`

### fix: keep Terraform plans working when canonical overrides are unset

- **Scope:** `terraform/gcp/main.tf`, `terraform/aws/main.tf`,
  `terraform/aws/variables.tf`, `scripts/validate-template.sh`
- **Why:** the `effective_*` locals guarded `trimspace()` with
  `var.x != null && ...`. Terraform 1.10 evaluates both operands of `&&`, so
  leaving `region`, `compute_type`, `database_instance_class` or
  `ollama_compute_type` unset (the default) failed `terraform plan` with
  "argument must not be null". The guards are now conditionals, with the same
  result for blank and set values. AWS `compute_model` is now `nullable = false`,
  so an explicit `null` means the `k3s` default instead of an error.
- **Sync impact:**
  - `terraform/{aws,gcp}/main.tf`, `terraform/aws/variables.tf` — manual merge
    (ask tier); no resource changes, plans are unchanged where they already
    worked
  - `scripts/validate-template.sh` — auto-sync safe; fails on any `.tf` line
    that guards a function call with `&&` or `||` on a null check

### fix: turn on Cloud SQL's own deletion protection

- **Scope:** `terraform/gcp/modules/sql/`, `terraform/gcp/variables.tf`,
  `terraform/gcp/terraform.tfvars.example`, `scripts/validate-template.sh`
- **Why:** `deletion_protection` only set the Terraform-side guard, so Cloud SQL
  reported `settings.deletionProtectionEnabled: false` and the console, gcloud
  or API could still delete the instance. The module now also sets
  `settings.deletion_protection_enabled` from the same variable.
- **Sync impact:**
  - `terraform/gcp/modules/sql/` — auto-sync safe. With
    `deletion_protection = true` the next apply makes one **in-place** update
    to the Cloud SQL instance (no replacement); with `false` (the default)
    the plan is unchanged. To delete a protected instance, set
    `deletion_protection = false` and apply first, as before.
  - `terraform/gcp/variables.tf`, `terraform/gcp/terraform.tfvars.example` —
    manual merge; description and example only
  - `scripts/validate-template.sh` — auto-sync safe; asserts the module keeps
    both guards tied to the variable

### fix: keep the DB password out of Terraform outputs; correct api_url; supported cert-manager

- **Scope:** `terraform/{aws,gcp}/outputs.tf`, `terraform/gcp/modules/sql/main.tf`,
  `scripts/setup.sh`, `scripts/validate-template.sh`, `DEPLOYMENT.md`,
  `config/secrets.env.example`
- **Why:** the `database_url` output embedded the database password, so
  `terraform output -json` and anything reading the state's outputs printed it
  (`sensitive` only hides it on screen). It is replaced by a non-secret
  `database_host` output; build `DATABASE_URL` from it and your tfvars.
  `api_url` (and the GCP `next_steps` `EVE_API_URL`) pointed at the apex
  domain instead of the API host, `api.<domain>`. `setup.sh` pinned
  cert-manager `v1.17.1`, which is out of support; it now installs `v1.21.3`.
  The password itself is still in state through the database user resource;
  once Terraform 1.11 is the minimum, `google_sql_user` can move to the
  write-only `password_wo`.
- **Sync impact:**
  - `terraform/{aws,gcp}/outputs.tf` — manual merge. **Action required** if a
    script reads `terraform output database_url`: read `database_host` and
    compose the URL instead. `api_url` changes value; no resource changes.
  - `scripts/setup.sh` — auto-sync safe. Affects new installs only: setup
    skips cert-manager when its namespace exists, so running clusters keep
    their version. Upgrade those with `helm upgrade cert-manager
    jetstack/cert-manager -n cert-manager --version v1.21.3 --set
    crds.enabled=true` after reading cert-manager's notes for each minor
    release in between.
  - `terraform/gcp/modules/sql/main.tf` — auto-sync safe (comment only)
  - `DEPLOYMENT.md`, `config/secrets.env.example` — manual merge; documents
    `database_host` and a URL-safe DB password (`/`, `+` and `=` break the
    URL, and RDS refuses `/`)
  - `scripts/validate-template.sh` — auto-sync safe; fails if any
    `outputs.tf` mentions `db_password`

### fix: give GCP managed-database snapshots a bucket inside the Eve prefix

The GCP overlay never set `EVE_DB_SNAPSHOT_BUCKET`, so Eve wrote managed-DB
snapshots to `eve-local-db-snapshots`, which nothing creates and which sits
outside the scoped storage grants. The storage module now creates
`<name_prefix>-eve-db-snapshots` (private, not versioned), and the GCP api and
orchestrator point `EVE_DB_SNAPSHOT_BUCKET` at it. The agent runtime cannot
read it.

- **Scope:** `terraform/gcp/modules/storage/`, `terraform/gcp/outputs.tf`,
  `k8s/overlays/gcp/api-deployment-patch.yaml`,
  `k8s/overlays/gcp/orchestrator-deployment-patch.yaml`,
  `scripts/validate-template.sh`, `terraform/gcp/tests/storage.tftest.hcl`
- **Sync impact:**
  - `terraform/gcp/modules/storage/` — auto-sync safe (adds one empty bucket)
  - `k8s/overlays/gcp/{api,orchestrator}-deployment-patch.yaml` — manual
    merge (one env var each; apply Terraform first so the bucket exists).
    If you already set `EVE_DB_SNAPSHOT_BUCKET` or `EVE_DEPLOYMENT_ID` through
    `secrets.env`, keep a bucket name under `<name_prefix>-eve-` or move the
    existing snapshots across.
  - `terraform/gcp/outputs.tf` — manual merge (adds `storage_db_snapshot_bucket`)

### fix: scope GCP storage IAM to Eve's buckets and give agent-runtime its own account

The GCP storage service account held `roles/storage.admin` on the whole
project, including `setIamPolicy` on every bucket, and `eve-agent-runtime`
was bound to it through Workload Identity. Code running in those pods (agent
code, pipeline scripts) could read or change any bucket in the project,
including backups or Terraform state, and grant outsiders lasting access.

- The platform account (`eve-api`, `eve-worker`, `eve-orchestrator`) now holds
  a custom role with the storage permissions of `roles/storage.admin` minus
  `*.setIamPolicy`, conditioned on `<name_prefix>-eve-*` buckets;
  `storage.buckets.create` on the project; and bucket IAM read/write on
  `<name_prefix>-eve-app-*` only, which Eve needs to make public app buckets
  readable.
- `eve-agent-runtime` gets a new account, `<name_prefix>-eve-agents`, with
  `roles/storage.objectViewer` on `<name_prefix>-eve-org-*` only. The agent
  runtime reads ingested files from org buckets and nothing else from GCS.
  The module refuses `eve-agent-runtime` in `workload_identity_ksas`.
- The GCP worker sets `EVE_STORAGE_APP_BUCKET_PREFIX=INSTANCE_PREFIX-eve-app`,
  so app buckets no longer share the org-bucket prefix.
- `terraform/gcp/modules/storage/README.md` documents the bucket names, the
  access model, the upgrade order, why Terraform state must stay out of the
  instance project, and why the template does not provision `shared`
  app-storage keys on GCP.

- **Scope:** `terraform/gcp/modules/storage/`, `terraform/gcp/outputs.tf`,
  `terraform/gcp/backend.tf.example`, `terraform/gcp/tests/storage.tftest.hcl`,
  `k8s/overlays/gcp/storage-workload-identity.yaml`,
  `k8s/overlays/gcp/worker-deployment-patch.yaml`,
  `scripts/validate-template.sh`
- **Sync impact:**
  - `terraform/gcp/modules/storage/` — **action required** (auto-synced, but
    must ship together with the overlay change below). On apply: creates the
    `<name_prefix>-eve-agents` account and three custom roles; replaces the
    project-wide `roles/storage.admin` grant (a `moved` block makes it
    create-before-destroy); deletes the `eve-agent-runtime` binding on the
    platform account. No service account is renamed and no bucket is touched.
    Before applying, confirm every bucket setting in your GCP overlay starts
    with `<name_prefix>-eve-`; any other bucket loses access. Follow the
    upgrade order in the module README.
  - `k8s/overlays/gcp/storage-workload-identity.yaml` — **action required**
    (manual merge): annotate `eve-agent-runtime` with
    `<name_prefix>-eve-agents@<project>.iam.gserviceaccount.com`. Deploy right
    after `terraform apply` and restart the agent runtime; in between, agent
    jobs cannot fetch `ingest://` resources.
  - `k8s/overlays/gcp/worker-deployment-patch.yaml` — manual merge. Safe as
    is unless apps already have object-store buckets (only possible if you
    configured `EVE_APP_STORAGE_*` yourself): the new prefix renames app
    buckets, so the next deploy creates new, empty ones. Copy the data first,
    or keep app buckets on the org prefix and accept that public app buckets
    then fail to publish.
  - `terraform/gcp/outputs.tf` — manual merge (adds
    `storage_app_bucket_prefix` and
    `storage_agent_runtime_service_account_email`)
  - `terraform/gcp/backend.tf.example`, `scripts/validate-template.sh`,
    `terraform/gcp/tests/` — auto-sync safe

### fix: order GCP Workload Identity bindings after the GKE cluster

The storage module's Workload Identity bindings built the pool name from the
project ID and had no dependency on the cluster that creates the pool, so a
first `terraform apply` could fail with `Identity Pool does not exist` and
need a second run. The GKE module now exports `workload_pool`, and the root
module passes it to the storage module, which orders the bindings after the
cluster. The member strings are unchanged.

- **Scope:** `terraform/gcp/modules/gke/outputs.tf`,
  `terraform/gcp/modules/storage/`, `terraform/gcp/main.tf`,
  `terraform/gcp/tests/storage.tftest.hcl`, `.github/workflows/template-ci.yml`
- **Sync impact:**
  - `terraform/gcp/modules/` — auto-sync safe (new `workload_pool` output and
    optional input; without the input the module behaves as before, and
    `terraform plan` shows no change for an existing install)
  - `terraform/gcp/main.tf` — manual merge (pass
    `workload_pool = module.gke.workload_pool` to `module "storage"`; plan
    shows no change)
  - `terraform/gcp/tests/`, `.github/workflows/template-ci.yml` — auto-sync
    safe (offline `terraform test` with a mocked Google provider; needs
    Terraform >= 1.7)

### fix: keep the Eve-native registry on GCP and refuse a registry that runs without auth

- **Scope:** `k8s/base/registry-deployment.yaml`, `k8s/base/registry-ingress.yaml`,
  `k8s/overlays/gcp/kustomization.yaml`, `k8s/overlays/gcp/registry-*.yaml` (new),
  `bin/eve-infra`, `scripts/validate-template.sh`, `scripts/lint-kubectl-safety.sh`,
  `DEPLOYMENT.md`, `README.md`
- **What changed:**
  - The registry image is now `distribution/distribution:3.1.2`, pinned by
    digest. The API signs registry tokens with an RFC 7638 JWK-thumbprint key
    ID; distribution v3 matches that against `rootcertbundle`, while
    `registry:2` keys trusted certificates by libtrust fingerprint and rejects
    every token the API issues.
  - The config is mounted at `/etc/distribution/config.yml`, the path v3 reads,
    and `args` names it explicitly. A v3 image with the old
    `/etc/docker/registry` mount ignores the config and serves with no auth.
  - The GCP overlay no longer deletes the registry that build and deploy push
    to (the GCP DNS module already creates `registry.<domain>`). It stores
    images on a 10 GiB `eve-registry-data` disk (default ReadWriteOnce class),
    rolls out with `Recreate`, and publishes `registry.eve.example.com` with
    TLS on the nginx class.
  - The registry ingress lifts ingress-nginx's 1 MiB body limit
    (`proxy-body-size: "0"`), which image layer pushes exceed.
  - `bin/eve-infra deploy` now checks, after rollout, that
    `https://<registry host>/v2/` answers 401 with `WWW-Authenticate: Bearer
    realm=`, and fails otherwise. Overlays without a registry ingress (`aws`)
    skip it; `--skip-registry-check` covers a first install before DNS and TLS
    exist.
  - `scripts/validate-template.sh` fails any overlay whose registry would not
    read its token-auth config, and tests the deploy check with stubs.
- **Sync impact:**
  - `k8s/base/registry-*.yaml` — action required for `aws-eks`: the registry
    moves from `registry:2` to distribution v3 (S3 storage layout unchanged).
    If your overlay already overrides the registry `image` or `args`, drop the
    override or point `args` at `/etc/distribution/config.yml`; an override
    still naming `/etc/docker/registry/config.yml` now fails validation and
    the registry will not start.
  - `k8s/overlays/gcp/` — manual merge for GCP instances that re-added the
    registry by hand (their own `registry-pvc.yaml`, `registry-*-patch.yaml`
    and kustomization entries). Keep your PVC and host values, take the
    template's files, and remove any registry `args` naming
    `/etc/docker/registry/config.yml`; keep your ingress class if you run
    Traefik. Then run `scripts/validate-template.sh` and deploy. GCP instances
    still on the template's registry deletion gain a new registry: set
    `EVE_REGISTRY_HOST` and `EVE_REGISTRY_SIGNING_KEY` in `secrets.env`, load
    the signing certificate with `scripts/setup.sh`, and set the host and
    realm in the overlay before deploying. A GCP instance that pushes app
    images to its own registry instead can keep the registry deletes in its
    kustomization; deploy then skips the check.
  - `bin/eve-infra`, `scripts/` — auto-sync safe (deploy fails loudly on an
    unauthenticated registry; the kubectl lint allows only the offline
    `annotate --local` form)
  - `DEPLOYMENT.md`, `README.md` — auto-sync safe

### fix: GCP org filesystem on the Terraform VPC, sized for cost, with a small profile

- **Scope:** `k8s/overlays/gcp/kustomization.yaml`,
  `k8s/overlays/gcp/org-fs/` (new; `filestore-storageclass.yaml` moved into
  `org-fs/filestore/`), `scripts/validate-template.sh`, `CLAUDE.md`
- **Why:** the Filestore StorageClass used `network: default`, which a project
  built by `terraform/gcp` does not have (it creates `<name_prefix>-vpc`), so
  provisioning failed on a fresh project. And Filestore bills the share it
  provisions, not the claim: the 5Gi org filesystem claim became a 1 TiB Basic
  HDD share (about GBP 146/month in London). The class now uses
  `INSTANCE_PREFIX-vpc` (fill it like the overlay's other placeholders), the
  claim asks for 100Gi (the Basic HDD minimum on GKE 1.33+, about GBP 48/month),
  and the org filesystem is chosen with a Kustomize component:
  `org-fs/filestore` (default, RWX) or `org-fs/disk` (a 10 GiB `standard-rwo`
  RWO disk, about GBP 1/month, with every agent runtime replica held on one
  node by required pod affinity).
- **Sync impact:**
  - `k8s/overlays/gcp/` — manual merge (ask tier). Default render changes only
    the StorageClass `network` and the claim's request (5Gi to 100Gi).
    - **Action required:** replace `INSTANCE_PREFIX` in
      `org-fs/filestore/filestore-storageclass.yaml`. StorageClass parameters
      are immutable: if your live `filestore-rwx` class has another network
      (`kubectl get storageclass filestore-rwx -o jsonpath='{.parameters.network}'`),
      keep that value, or `kubectl apply` will refuse the class.
    - The 100Gi request is an increase, which Kubernetes allows on a bound
      claim; on an existing 1 TiB share it is below the provisioned size, so
      nothing is resized.
    - Selecting `org-fs/disk` on a running instance is **not** an in-place
      change: the claim's storage class and access mode are immutable. Back up
      `/org`, scale the agent runtime to 0, delete the claim (this deletes its
      volume), switch the component, deploy, restore `/org`. Steps are in
      `org-fs/disk/kustomization.yaml`. Do not use the disk profile with
      `EVE_SCRIPT_K8S_RUNNER=true`: worker runner pods mount `/org` and have no
      node selector.
  - `scripts/validate-template.sh` — auto-sync safe; asserts the default
    Filestore network and size, and renders the disk profile
  - `CLAUDE.md` — manual merge; adds the org filesystem cost table

### fix: drop the unread agent_runtime settings; show the always-on agents node

- **Scope:** `config/platform.yaml`, `CLAUDE.md`,
  `terraform/gcp/terraform.tfvars.example`, `scripts/validate-template.sh`
- **Why:** `agent_runtime.replicas` and `agent_runtime.capacity` in
  `platform.yaml` were read by nothing; the overlays set the agent runtime's
  replicas and `AGENT_RUNTIME_CAPACITY`. Honouring the key now would silently
  change running instances: the template default says 3 while the `aws`
  overlay deploys 1, and `platform.yaml` is never synced, so every k3s instance
  would jump to 3 runtimes on one host. The orchestrator's
  `EVE_AGENT_RUNTIME_URLS` also names each pod, so a count above 3 needs more
  than a replica number. The keys are replaced by a comment that points at the
  overlay. The sizing docs now say the agents pool always keeps one node,
  because the agent runtime and BuildKit are pinned to it.
- **Sync impact:**
  - `config/platform.yaml` — never-synced; nothing changes for existing
    instances. You may delete `agent_runtime:` from your copy; it was never read.
  - `CLAUDE.md`, `terraform/gcp/terraform.tfvars.example` — manual merge; docs
    and comments only
  - `scripts/validate-template.sh` — auto-sync safe; fails if an overlay runs an
    agent runtime replica that `EVE_AGENT_RUNTIME_URLS` does not map. A
    downstream overlay that raised replicas without extending the map will now
    fail validation, which is the point: work routed to that pod was failing.

### fix: keep API signing keys out of other services and carry PEM keys intact

- **Scope:** `scripts/render-k8s-secrets.py` (new), `bin/eve-infra`,
  `scripts/setup.sh`, `k8s/base/api-deployment.yaml`, `k8s/base/app-secret.yaml`,
  `k8s/overlays/{aws,aws-eks}/api-deployment-patch.yaml`,
  `k8s/overlays/aws-eks/{kustomization.yaml,remove-app-secret.yaml}`,
  `config/secrets.env.example`, `DEPLOYMENT.md`, `README.md`,
  `skills/eve-infra-ops/`, `scripts/validate-template.sh`,
  `tests/test_k8s_secrets.py` (new)
- **Why:** every service loaded every platform secret through `envFrom: eve-app`,
  so the worker, orchestrator, gateway, SSO and agent runtime held the keys
  that mint user and registry tokens and decrypt org secrets. Separately,
  `kubectl create secret --from-env-file` reads one line per key, so the
  multi-line PEM keys the example promised could not be synced at all.
- **What changed:** `secrets sync` (and `setup.sh`, which now calls it) renders
  two secrets from `config/secrets.env`: `eve-app` for every service and
  `eve-api-keys` for the keys only the API reads (`EVE_SECRETS_MASTER_KEY`,
  `EVE_AUTH_PRIVATE_KEY`, `EVE_AUTH_JWT_SECRET`, `EVE_REGISTRY_SIGNING_KEY`,
  `EVE_BOOTSTRAP_TOKEN`, `EVE_ORG_FS_LINK_TOKEN_SECRET`,
  `EVE_GITHUB_WEBHOOK_SECRET`, `SUPABASE_AUTH_SERVICE_KEY`). Only `eve-api`
  mounts `eve-api-keys` (optional reference). The env file accepts
  double-quoted multi-line values (and `\n` escapes inside double quotes);
  unquoted values are read verbatim as before. The example documents
  `EVE_AUTH_PRIVATE_KEY` with a generation command, marks the API-only keys,
  and moves LLM and GitHub keys to Eve org secrets. The aws-eks overlay no
  longer renders the blank `eve-app` placeholder, which a deploy would have
  applied over the synced values.
- **Sync impact:**
  - `k8s/base/`, `bin/eve-infra`, `scripts/` — **action required, in order:**
    sync, then `eve-infra deploy` (the API now also loads the optional
    `eve-api-keys`; nothing else changes yet), then `eve-infra secrets sync`
    (moves the API-only keys out of `eve-app`), then restart services so they
    drop the old values. `secrets sync` refuses to run until the live
    `eve-api` Deployment loads `eve-api-keys`, so the keys cannot vanish from
    the API on a restart. `secrets sync` now needs `python3`.
  - `config/secrets.env` — no edit needed for single-line values. Values that
    start with a quote are now unquoted (`KEY="v"` gives `v`, where kubectl
    kept the quotes); a value that opens a quote must close it at the end of
    a line. A PEM must be wrapped in double quotes; an unquoted one is
    rejected with the line number, never the value.
  - `k8s/overlays/{aws,aws-eks}/api-deployment-patch.yaml` — manual merge
    (`EVE_REGISTRY_SIGNING_KEY` now reads from `eve-api-keys`)
  - `k8s/overlays/aws-eks/` — manual merge (add `remove-app-secret.yaml` and
    its patch entry)
  - `config/secrets.env.example`, `DEPLOYMENT.md`, `skills/eve-infra-ops/` —
    informational
  - `scripts/validate-template.sh`, `tests/` — template CI: renders must not
    contain `eve-app`/`eve-api-keys`, and only `eve-api` may reference
    `eve-api-keys` or an API-only key

### ci: run the template contract check only in the canonical template

- **Scope:** `.github/workflows/template-ci.yml`, `scripts/validate-template.sh`
- **Why:** repos created from the template inherited Template CI, whose
  `validate-template.sh` asserts template-only facts (floating tags, the
  instance-name scrub) and so failed on every instance push.
- **What changed:** the `manifests` job runs only in
  `eve-horizon/eve-horizon-infra`, mirroring the inverse guard on
  `deploy.yml`. The `terraform` job (fmt and credential-free validate) still
  runs everywhere. Template CI now asserts both guards.
- **Sync impact:**
  - `.github/workflows/template-ci.yml` — auto-sync safe (instances stop
    running the manifests job; Terraform checks continue)
  - `scripts/validate-template.sh` — template-only CI assertion

### fix: pass the deploy version input through the environment

- **Scope:** `.github/workflows/deploy.yml`, `scripts/validate-template.sh`,
  `tests/test_workflow_inputs.py` (new)
- **Why:** the `Resolve version` step expanded `${{ inputs.version }}` inside
  `run:`, so the dispatch input was spliced into the shell script before bash
  parsed it (script injection by anyone who can dispatch the workflow), and
  the unchecked version then reached perl, yq and git commands.
- **What changed:** the input and the config version reach the script as
  `INPUT_VERSION` and `CONFIG_VERSION`, and the resolved version must look
  like `0.1.28` (optionally `-<pre-release>`) or the deploy stops before
  touching the cluster. Template CI checks that no workflow expands
  `inputs.*`, `github.event.*` or `github.head_ref` inside a script, and runs
  the step against hostile inputs.
- **Sync impact:**
  - `.github/workflows/deploy.yml` — manual merge (one step changes; deploys
    of a non-release version string such as `latest` now fail fast)
  - `scripts/validate-template.sh`, `tests/` — template-only CI

### fix: refuse to deploy an overlay that still carries template placeholders

- **Scope:** `scripts/check-placeholders.sh` (new), `bin/eve-infra`,
  `.github/workflows/deploy.yml`, `DEPLOYMENT.md`,
  `scripts/validate-template.sh`, `tests/test_placeholders.py` (new)
- **Why:** the overlays ship with values each instance must fill by hand
  (`INSTANCE_PREFIX`, `GCP_PROJECT`, `YOUR_REGION`, `REPLACE_*`, `example.com`
  hosts), and nothing stopped a deploy that still carried them: it applied
  Workload Identity bindings, buckets, ingress hosts and TLS for values that
  do not exist.
- **What changed:** `eve-infra deploy` renders the overlay once, before
  migrations, and stops if any placeholder survives, listing each with the
  resources that carry it; the same rendered manifests are then applied. The
  deploy workflow runs the same check before touching the cluster.
  `EVE_ALLOW_PLACEHOLDERS=1` (environment, or repository variable for the
  workflow) downgrades the check to a warning. Rendering these values from
  `config/platform.yaml` is not part of this change.
- **Sync impact:**
  - `bin/eve-infra`, `scripts/check-placeholders.sh`,
    `.github/workflows/deploy.yml` — **action required if your rendered
    overlay still contains a placeholder** (even an unused one): deploys now
    stop until you fill it, or set `EVE_ALLOW_PLACEHOLDERS=1`. Run
    `kubectl kustomize k8s/overlays/<overlay> | scripts/check-placeholders.sh`
    after syncing to see whether you are affected.
  - `DEPLOYMENT.md` — informational
  - `scripts/validate-template.sh`, `tests/` — template-only CI

### fix: pin the ingress-nginx chart that setup installs

- **Scope:** `scripts/setup.sh`, `.github/workflows/deploy.yml` (comment only),
  `DEPLOYMENT.md`, `scripts/validate-template.sh`
- **Why:** `setup.sh` installed ingress-nginx on GKE and AWS EKS from whatever
  chart was newest at the time, while the deploy workflow pins aws-eks
  clusters to chart 4.14.3, so two installs a week apart could differ and an
  EKS cluster could flip versions on its first CI deploy.
- **What changed:** both setup paths pass `--version
  "$INGRESS_NGINX_CHART_VERSION"`, default `4.14.3` (the deploy workflow's
  pin), overridable per run. `DEPLOYMENT.md` records that ingress-nginx is
  retired upstream (no releases after March 2026; final charts 4.14.5 and
  4.15.1) and that the planned successor is the Gateway API. Template CI
  fails if an ingress-nginx Helm command lacks `--version` or the two pins
  differ.
- **Sync impact:**
  - `scripts/setup.sh` — auto-sync safe (affects only new ingress-nginx
    installs; setup skips an existing `ingress-nginx` namespace)
  - `.github/workflows/deploy.yml` — auto-sync safe (comment only; the pin is
    unchanged)
  - `DEPLOYMENT.md` — informational
  - `scripts/validate-template.sh` — template-only CI assertion

### fix: run a current BuildKit by digest with GC sized to its cache volume

- **Scope:** `k8s/base/buildkitd-deployment.yaml`, `k8s/base/buildkitd-pvc.yaml`
  (comment), `scripts/validate-template.sh`
- **Why:** BuildKit `v0.12.5` bundles a runc without the 2025
  container-escape fixes, and it runs privileged. Its GC kept up to 12000 MB,
  which overflows the cache volume as soon as an overlay shrinks it.
- **What changed:** `moby/buildkit:v0.34.1` pinned by digest, and GC set as
  `Reserved,MinFree,MaxUsed` = `2000,3000,15000` MB for the 20Gi
  `buildkitd-cache` volume. Template CI fails if a render's BuildKit image is
  not digest-pinned or its MinFree + MaxUsed does not fit the rendered cache
  volume. Privileged mode is unchanged (rootless BuildKit is a separate
  change).
- **Sync impact:**
  - `k8s/base/` — auto-sync safe, with two checks. If your overlay resizes
    `buildkitd-cache`, scale the GC values to fit it (for a 10Gi volume,
    `2000,1500,7500`). If your overlay overrides the BuildKit image, keep it at
    v0.17 or newer: older releases do not accept the three-value
    `--oci-worker-gc-keepstorage`. The image change rolls the buildkitd pod;
    with a ReadWriteOnce cache, a replacement pod scheduled on another node
    waits for the old pod to release the volume. If the rollout stalls, delete
    the old `buildkitd` pod (the cache is disposable).
  - `scripts/validate-template.sh` — template-only CI assertion

### fix: give the db status and connect pods only the database URL

- **Scope:** `bin/eve-infra`, `scripts/pg-env-from-url.awk` (new), `README.md`,
  `scripts/validate-template.sh`, `tests/test_db_pods.py` (new)
- **Why:** the throwaway psql pods behind `eve-infra db status` and
  `db connect` loaded every key in `eve-app` with `envFrom`, ran an unpinned
  Docker Hub `postgres:16-alpine`, and handed `DATABASE_URL` to psql as an
  argument, where process listings (and agents that record command lines)
  can read the password.
- **What changed:** the pods load `DATABASE_URL` alone through
  `secretKeyRef`, run `postgres:17.11-alpine` pinned to its multi-arch index
  digest, and convert the URL into libpq variables (`PGHOST`, `PGPASSWORD`,
  ...) before psql starts with no connection arguments. The converter
  decodes percent-encoding, passes on libpq query parameters such as
  `sslmode`, and fails without echoing the URL. Template CI runs both
  commands against a stub cluster and checks the pod spec and psql's
  arguments.
- **Sync impact:**
  - `bin/eve-infra`, `scripts/` — auto-sync safe. `db status` and
    `db connect` now need `jq` locally (already used by `secrets show`). A
    multi-host `DATABASE_URL` is refused by these two commands; deployments
    are unaffected. The psql client moves from 16 to 17, which supports
    PostgreSQL 15 servers.
  - `README.md` — informational
  - `scripts/validate-template.sh`, `tests/` — template-only CI

### fix: let slow-booting workers start, and wait for them on deploy

- **Scope:** `k8s/base/worker-deployment.yaml`,
  `k8s/base/agent-runtime-deployment.yaml`, `bin/eve-infra`,
  `.github/workflows/deploy.yml`, `DEPLOYMENT.md`,
  `scripts/validate-template.sh`, `tests/test_rollout_timeout.py` (new)
- **Why:** the worker can spend about three minutes setting up harness CLI
  tooling before it serves `/health`. `eve-infra deploy` waited 120s per
  rollout (the workflow 180s), and the liveness probe (20s delay, 3 failures)
  left little margin before restarting a booting worker.
- **What changed:** the worker and agent runtime get a `startupProbe` on
  `/health` that allows up to 10 minutes, holding off liveness and readiness
  until the first success (a fast boot is unaffected). `deploy` and
  `restart` wait `EVE_ROLLOUT_TIMEOUT` per rollout (default `600s`); the deploy
  workflow uses the repository variable `EVE_ROLLOUT_TIMEOUT` with the same
  default. `deploy` now exits non-zero, after checking every workload, when a
  rollout has not finished, instead of printing "timed out" and "Deploy
  complete". Template CI checks each render's startup budget and the
  timeout handling.
- **Sync impact:**
  - `k8s/base/` — auto-sync safe (adds probes; rolls the worker and agent
    runtime on the next deploy)
  - `bin/eve-infra` — auto-sync safe, but scripts that ran `eve-infra deploy`
    and ignored its result now see exit status 1 when a rollout does not
    finish
  - `.github/workflows/deploy.yml` — auto-sync safe (rollout waits go from
    180s to 600s unless `EVE_ROLLOUT_TIMEOUT` is set)
  - `DEPLOYMENT.md` — informational
  - `scripts/validate-template.sh`, `tests/` — template-only CI

### fix: isolate runner pods and guard the worker's cluster rights

Runner pods execute job code but ran as `eve-worker`, whose token can read
every Secret in the cluster and create pods anywhere. They now run as a new
`eve-runner` account with no RBAC, no cloud identity and no mounted token. The
worker's RBAC drops rights its code never uses, and on GKE two admission
policies stop Eve's controller identities from creating privileged or
host-level pods, non-ClusterIP Services, or anything in system namespaces.

- **Scope:** `k8s/base/runner-serviceaccount.yaml` (new),
  `k8s/base/kustomization.yaml`, `k8s/base/worker-deployment.yaml`,
  `k8s/base/worker-rbac.yaml`, `k8s/overlays/aws/worker-deployment-patch.yaml`,
  `k8s/overlays/gcp/admission-policies.yaml` (new),
  `k8s/overlays/gcp/kustomization.yaml`, `scripts/validate-template.sh`,
  `scripts/validate-template.d/` (new)
- **Sync impact:**
  - `k8s/base/` — auto-sync safe for the platform. `EVE_RUNNER_SERVICE_ACCOUNT`
    moves to `eve-runner`; runner pods reach only the Eve API and never used
    their token. The worker loses `watch` (all resources), `list` on Secrets,
    `pods/exec`, `pods/status`, and DaemonSets, StatefulSets, ReplicaSets and
    CronJobs; no worker code path uses them. **Action required** only if your
    own pipeline scripts call `kubectl` with the worker's token (in-process
    script steps): those calls lose these rights, by design.
  - `k8s/overlays/aws/worker-deployment-patch.yaml` — manual merge (this patch
    replaces the whole env list; set `EVE_RUNNER_SERVICE_ACCOUNT=eve-runner`).
  - `k8s/overlays/gcp/` — manual merge. Needs Kubernetes 1.30 or later
    (`admissionregistration.k8s.io/v1`; GKE REGULAR channel). The guards match
    only `eve-worker`, `eve-orchestrator`, `eve-agent-runtime` and
    `eve-runner`; operator and CI applies are unaffected. They refuse stable
    egress (hostNetwork) and TCP ingress (LoadBalancer) workloads, which the
    GKE overlay leaves off (`EVE_COMPUTE_MODEL=gke`, no
    `EVE_TCP_INGRESS_PROVIDER`); add any extra system namespaces of yours to
    the scope guard's list. Not added to `aws` or `aws-eks`: their supported
    stable-egress and NLB TCP-ingress features need hostNetwork pods and
    LoadBalancer Services, and the k3s install is not pinned to 1.30+.
  - `scripts/` — template CI assertions (runner account, worker env and RBAC
    in every overlay; GKE admission policies fail closed and deny).

### fix: enforce NetworkPolicy on new GKE clusters and fence internal services

GKE clusters were created without a NetworkPolicy enforcer, so even the base
BuildKit policy did nothing, and the worker, agent runtime and orchestrator
endpoints (no authentication of their own) were reachable from agent code and
user apps. New clusters now use GKE Dataplane V2, and the GKE overlay adds
ingress policies for those services, runner pods and mailpit.

- **Scope:** `terraform/gcp/modules/gke/` (`main.tf`, `variables.tf`,
  `outputs.tf`), `terraform/gcp/main.tf`, `terraform/gcp/variables.tf`,
  `terraform/gcp/outputs.tf`, `terraform/gcp/terraform.tfvars.example`,
  `k8s/overlays/gcp/network-policies.yaml` (new),
  `k8s/overlays/gcp/kustomization.yaml`, `scripts/validate-template.sh`,
  `scripts/validate-template.d/` (new)
- **Why the Dataplane V2 default cannot hurt an existing cluster:** GKE sets
  the datapath only at cluster creation; changing `datapath_provider` on an
  existing cluster forces Terraform to destroy and recreate it. The module
  now sets it from `enable_dataplane_v2` (default `true`) **and** lists it in
  `lifecycle.ignore_changes`. New clusters get Dataplane V2; for an existing
  cluster the setting is ignored, so `terraform plan` shows no change and
  never proposes a replacement. A default of `false` would have left every
  new instance unprotected; a default of `true` without the ignore would
  have destroyed existing clusters on their next apply.
- **Sync impact:**
  - `terraform/gcp/modules/gke/` — auto-sync safe (no plan change for an
    existing cluster). **Action required to get enforcement on an existing
    cluster:** run `terraform output network_policy_enforced`. If it is
    `false`, the NetworkPolicies are inert until the cluster is rebuilt
    (`terraform apply -replace=module.gke.google_container_cluster.main`,
    a full rebuild with downtime: redeploy the platform and apps after).
  - `terraform/gcp/{main,variables,outputs}.tf`, `terraform.tfvars.example` —
    manual merge (pass `enable_dataplane_v2` through and expose
    `network_policy_enforced`; the module default applies if you skip it).
  - `k8s/overlays/gcp/` — manual merge. Ingress only: the API and
    orchestrator may call the worker; the orchestrator, API and worker the
    agent runtime; the API and worker the orchestrator; the worker and agent
    runtime their runner pods; the API and GoTrue mailpit's SMTP port.
    Egress is unchanged. If you run extra in-cluster callers of these
    services (for example a second worker deployment or a metrics scraper),
    add them before rebuilding onto Dataplane V2.
  - Not added to `aws` or `aws-eks`. k3s enforces NetworkPolicy natively and
    EKS only with the VPC CNI network-policy agent enabled; reuse the file
    there once verified on a live cluster.
  - `scripts/` — template CI assertions (expected policies, selectors and
    callers match rendered workloads; Dataplane V2 default and the
    replacement guard in the GKE module).

### fix: stop custom domains from claiming platform hosts on GCP

The GCP DNS module published an apex and a `*.<domain>` wildcard at the
platform ingress, so any name under the domain passed custom-domain DNS
verification and a project could serve `auth.<domain>`, `sso.<domain>` or
similar. DNS now publishes only named platform hosts and `*.apps.<domain>`,
and a GKE admission policy refuses tenant ingresses on platform hosts.

- **Scope:** `terraform/gcp/modules/dns/` (`main.tf`, `variables.tf`,
  `outputs.tf`), `terraform/gcp/main.tf`, `terraform/gcp/variables.tf`,
  `terraform/gcp/outputs.tf`, `terraform/gcp/terraform.tfvars.example`,
  `k8s/overlays/gcp/ingress-host-policy.yaml` (new),
  `k8s/overlays/gcp/kustomization.yaml`,
  `k8s/overlays/gcp/{worker,api}-deployment-patch.yaml`,
  `scripts/validate-template.sh`, `scripts/validate-template.d/` (new)
- **What changes:**
  - DNS: A records for `dns_platform_hosts` (default `api`, `registry`,
    `auth`, `sso`, `dashboard`, `ingress`) under the domain, plus
    `*.apps.<domain>`. The apex and `*.<domain>` exist only while
    `dns_legacy_wildcard_records = true` (default `false`). The existing
    `registry` record moves into the new set in state (`moved` block), so it
    is not recreated. Root output `api_url` now reports `https://api.<domain>`.
  - Admission (`eve-ingress-host-guard`, Kubernetes 1.30+): an Ingress
    written by an Eve controller, or by anyone into an environment
    namespace (label `eve.env_id`), may only use hosts under the platform
    domain that are under the app domain; no wildcard or host-less rules
    and no default backend. Custom domains outside the platform domain and
    the platform's own ingresses in `eve` are unaffected.
  - The GKE API now gets `EVE_DEFAULT_DOMAIN` (it had none, so its
    custom-domain check did nothing), and the overlay placeholder becomes
    `apps.eve.example.com` to match the DNS app wildcard.
- **Sync impact:**
  - `terraform/gcp/modules/dns/` — **action required: this removes live DNS
    records.** Names that resolved only through `*.<domain>` or the apex stop
    resolving. Migrate in two applies:
    1. List every host you serve under `<domain>` (platform ingresses, any
       ops tools, custom domains under the domain). Add any label missing
       from the default to `dns_platform_hosts`.
    2. Apply with `dns_legacy_wildcard_records = true`: this adds the named
       records and keeps the apex and wildcard. Check each host resolves
       (`dig +short api.<domain>`).
    3. Remove the setting (default `false`) and apply again: Terraform
       destroys only the apex and `*.<domain>` records.
    A single apply also works, but destroys the wildcard while creating the
    named records, so a resolver may cache a miss for a platform host for up
    to the zone's negative TTL (Cloud DNS default: 300 seconds).
  - `terraform/gcp/{main,variables,outputs}.tf`, `terraform.tfvars.example` —
    manual merge (pass the two DNS variables through; fix `api_url`).
  - `k8s/overlays/gcp/` — manual merge. Set the policy's `platformDomain` to
    your Terraform `domain` and `appDomain` to your `EVE_DEFAULT_DOMAIN`
    (`apps.<domain>`), and set the same `EVE_DEFAULT_DOMAIN` on the API.
    Before applying, check `kubectl get ingress -A` for environment-namespace
    hosts under `<domain>` but outside `apps.<domain>`: their next deploy
    will be refused; move them to an app alias or a domain you own.
  - `scripts/` — template CI assertions (no unconditional apex or wildcard
    record; DNS host defaults agree; policy domains, worker and API
    `EVE_DEFAULT_DOMAIN` and the API host agree; every platform ingress host
    has a record).

### fix: block the API's /internal routes at the public ingress

The API ingress sent every path to `eve-api`, so `/internal/*` (secrets,
job and registry tokens, chat routing) was reachable from the internet and
guarded only by the internal key. The dashboard's `/api` proxy exposed the
same routes on the dashboard host. Every overlay now routes those paths to a
Service with no endpoints (503), keeping `/internal/registry/token`, the
registry's token realm, on the API host.

- **Scope:** `k8s/overlays/{aws,aws-eks,gcp}/internal-block-ingress.yaml`
  (new), `k8s/overlays/{aws,aws-eks,gcp}/kustomization.yaml`,
  `scripts/validate-template.sh`, `scripts/validate-template.d/` (new)
- **How it works:** a second Ingress on the API host routes
  `/internal/registry/token` (Exact) to `eve-api` and the `/internal` prefix
  to `eve-api-internal-block`, a Service whose selector matches no pod.
  ingress-nginx (all three overlays) and Traefik both prefer Exact over
  Prefix and the longer prefix over `/`, so the API's own `/` route is
  untouched. A third Ingress on the dashboard host blocks `/api/internal`
  in every letter case: the dashboard's Express mount matches `/api`
  case-insensitively, while ingress path matching is case-sensitive (the
  API's Fastify routes are case-sensitive, so `/internal` needs no variants).
  No new Pods, and no cert-manager annotation (the API host reuses
  `eve-api-tls` where the overlay has one).
- **Sync impact:**
  - `k8s/overlays/` — manual merge. Copy your `eve-api` and `eve-dashboard`
    Ingress host, class and TLS into the two new Ingresses (template CI
    checks they match). If you replaced ingress-nginx with another
    controller, keep the same class on all three. In-cluster callers use
    `http://eve-api:4701` and are unaffected; anything outside the cluster
    that calls `/internal/*` other than the registry token endpoint through
    the public host now gets 503. The Eve platform has no such caller.
  - `scripts/` — template CI assertions (block Ingresses on the API and
    dashboard hosts in every overlay, same host, class and TLS; the token
    path is the only kept path and matches the registry realm; the block
    Service selects no workload).

## [2026-08-25]

### fix: preserve migration safety and complete auth bootstrap overlays

- **Scope:** `bin/eve-infra`, `k8s/base/supabase-auth-deployment.yaml`,
  `k8s/overlays/{aws-eks,gcp}/auth-bootstrap-job.yaml`,
  `scripts/validate-template.sh`, `skills/eve-template-backport-sync/`
- **Sync impact:**
  - `bin/eve-infra`, auth URL paths, and auth bootstrap jobs — auto-sync safe
    (deploy runs migrations before rollout, migration commands apply only the
    one-shot Job, migration status is inspectable, and every supported overlay
    has the auth bootstrap file consumed by the deploy workflow)
  - `scripts/validate-template.sh` — template-only CI assertion
  - `skills/eve-template-backport-sync/` — auto-sync safe; restores the
    mandatory instance-value scrub before public-template staging

### ci: validate the generic infrastructure template

- **Scope:** `.github/workflows/`, `scripts/validate-template.sh`,
  `.upstream-sync.example.json`, `CLAUDE.md`, `skills/upstream-sync/`,
  `skills/manual-test-scenarios/`, `terraform/aws-backend/outputs.tf`,
  `terraform/{aws,gcp}/.terraform.lock.hcl`
- **Sync impact:**
  - `.github/workflows/`, `scripts/validate-template.sh` — auto-sync safe (the
    canonical template skips instance-only deploy, health, and release checks;
    downstream copies continue to run them, while template CI renders all
    overlays and validates coordinated upgrades and Terraform)
  - `.upstream-sync.example.json`, `CLAUDE.md`, `skills/upstream-sync/` — manual
    merge (generic skills remain auto-sync; instance-owned manual test guidance
    is explicitly `never`)
  - `skills/manual-test-scenarios/` — remove from the public template only;
    downstream instances must retain their private deployment-specific copy
  - `terraform/aws-backend/outputs.tf` — auto-sync safe (removes duplicate
    output declarations; the documented outputs remain in `main.tf`)
  - `terraform/{aws,gcp}/.terraform.lock.hcl` — auto-sync safe (records every
    provider required by credential-free validation)

## [2026-08-24]

### fix: separate source publication from instance deployment

- **Scope:** `.github/workflows/deploy.yml`, `bin/eve-infra`, `k8s/overlays/aws/`, `k8s/overlays/aws-eks/`, `k8s/overlays/gcp/`, `UPGRADE.md`, `skills/eve-horizon-release/SKILL.md`, `skills/eve-infra-ops/SKILL.md`, `skills/redeploy-if-necessary/SKILL.md`, `CLAUDE.md`
- **Sync impact:**
  - `.github/workflows/deploy.yml` — manual merge (removes the obsolete `repository_dispatch` trigger and payload version path; preserves deploy tags and manual dispatch)
  - `bin/eve-infra`, service and runner-image overlay patches — auto-sync safe (add missing dashboard/service overrides, move AWS-EKS from GHCR to public ECR, make GCP registry deletion Kustomize-v5-safe, upgrade all seven services, and use the published `worker` image for runner pods instead of legacy `worker-full`)
  - `UPGRADE.md`, `skills/`, `CLAUDE.md` — auto-sync safe (documents the public source's publish-only release model, ECR-backed version discovery, and instance-owner rollout boundary)

## [2026-02-14]

### feat: add upstream sync system
- **Scope:** `skills/upstream-sync/`, `.upstream-sync.example.json`, `CHANGELOG.md`, `bin/eve-infra`, `CLAUDE.md`
- **Sync impact:**
  - `skills/upstream-sync/SKILL.md` — auto-sync safe (new file)
  - `.upstream-sync.example.json` — auto-sync safe (new file, template only)
  - `CHANGELOG.md` — auto-sync safe (new file, template history)
  - `bin/eve-infra` — auto-sync safe (new `sync` subcommand, no breaking changes)
  - `CLAUDE.md` — manual merge (new section added; preserve downstream customizations)

### feat: add optional Ollama GPU module for on-demand inference
- **Scope:** `terraform/aws/modules/ollama/`, `terraform/aws/main.tf`, `terraform/aws/variables.tf`, `terraform/aws/outputs.tf`, `terraform/aws/terraform.tfvars.example`, `config/platform.yaml`, `config/secrets.env.example`, `DEPLOYMENT.md`
- **Sync impact:**
  - `terraform/aws/modules/ollama/` — auto-sync safe (new module)
  - `terraform/aws/main.tf` — manual merge (new module block added; keep your existing variable values)
  - `terraform/aws/variables.tf` — manual merge (new `ollama_*` variables added with defaults)
  - `terraform/aws/outputs.tf` — manual merge (new Ollama outputs added)
  - `terraform/aws/terraform.tfvars.example` — informational (review new variables, add to your tfvars if enabling Ollama)
  - `config/platform.yaml` — never sync (new `ollama` section; add manually if desired)
  - `config/secrets.env.example` — informational (new `EVE_OLLAMA_BASE_URL` key)
  - `DEPLOYMENT.md` — manual merge (new Ollama deployment section added)
  - `terraform/aws/modules/ec2/` — auto-sync safe (IAM profile variable added)

### docs: plan for first-class Ollama GPU module
- **Scope:** `docs/plans/ollama-gpu-module.md`
- **Sync impact:** informational only (planning document, no operational effect)

## [2026-02-11]

### feat: enable managed Postgres reconciler in AWS overlay
- **Scope:** `k8s/overlays/aws/orchestrator-deployment-patch.yaml`
- **Sync impact:** manual merge (adds `MANAGED_POSTGRES=true` env var to orchestrator; review if you've customized this patch)

### fix: correct skills directory structure and manifest
- **Scope:** `.gitignore`, `skills.txt`, `skills/eve-infra-ops/SKILL.md`, `CLAUDE.md`
- **Sync impact:**
  - `skills/`, `skills.txt` — auto-sync safe
  - `.gitignore` — manual merge (new ignore patterns for installed skills)
  - `CLAUDE.md` — manual merge (skills section updated)

### feat: add agent skills, CLAUDE.md, and local kubeconfig support
- **Scope:** `skills/eve-infra-ops/SKILL.md`, `CLAUDE.md`, `bin/eve-infra`, `.gitignore`
- **Sync impact:**
  - `skills/eve-infra-ops/SKILL.md` — auto-sync safe (new file)
  - `CLAUDE.md` — manual merge (new file; may have downstream customizations)
  - `bin/eve-infra` — auto-sync safe (kubeconfig resolution added)
  - `.gitignore` — manual merge (new entries)

### fix: db-migrate-job kustomize handling
- **Scope:** `k8s/overlays/aws/kustomization.yaml`, `k8s/overlays/aws/db-migrate-job-patch.yaml`
- **Sync impact:** auto-sync safe (migration job excluded from kustomize build to prevent apply conflicts; the CLI handles it separately)

### docs: add README, DEPLOYMENT, and UPGRADE guides
- **Scope:** `README.md`, `DEPLOYMENT.md`, `UPGRADE.md`
- **Sync impact:** manual merge (if you've customized these docs, merge upstream additions; otherwise accept)

### feat: add operational CLI, deploy workflows, and cluster setup script
- **Scope:** `bin/eve-infra`, `scripts/setup.sh`, `.github/workflows/deploy.yml`, `.github/workflows/health-check.yml`, `.github/workflows/upgrade-check.yml`
- **Sync impact:**
  - `bin/eve-infra` — auto-sync safe
  - `scripts/` — auto-sync safe
  - `.github/workflows/` — auto-sync safe

### feat: add platform.yaml config schema and secrets.env.example
- **Scope:** `config/platform.yaml`, `config/secrets.env.example`
- **Sync impact:**
  - `config/platform.yaml` — never sync (instance-specific)
  - `config/secrets.env.example` — informational (review for new required keys)

### feat: seed infra template with k8s manifests and AWS terraform modules
- **Scope:** `k8s/base/`, `k8s/overlays/aws/`, `terraform/aws/`, `.gitignore`
- **Sync impact:**
  - `k8s/base/` — auto-sync safe
  - `k8s/overlays/aws/` — manual merge (contains your image tags and secrets)
  - `terraform/aws/modules/` — auto-sync safe
  - `terraform/aws/main.tf`, `variables.tf`, `outputs.tf` — manual merge (your variable values)
  - `.gitignore` — manual merge
