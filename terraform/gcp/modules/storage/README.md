# GCS storage module

Object storage for the Eve platform on GCP: the internal bucket, the service
accounts that Eve pods use through Workload Identity, and the IAM that limits
those accounts to Eve's own buckets. Org and app buckets are created at run
time by the API and the worker.

## Bucket names

Every bucket Eve uses must be named `<name_prefix>-eve-*`. The service
accounts below have no access outside that prefix, so a bucket named any
other way fails with `403`.

| Bucket | Name | Set on | Created by |
|---|---|---|---|
| Internal | `<name_prefix>-eve-internal` | `EVE_STORAGE_INTERNAL_BUCKET` (api, worker) | this module |
| DB snapshots | `<name_prefix>-eve-db-snapshots` | `EVE_DB_SNAPSHOT_BUCKET` (api, orchestrator) | this module |
| Org | `<name_prefix>-eve-org-<org>` | `EVE_STORAGE_ORG_BUCKET_PREFIX` (api, worker, agent-runtime) | API, on first use |
| App | `<name_prefix>-eve-app-<org>-<project>-<env>-<bucket>` | `EVE_STORAGE_APP_BUCKET_PREFIX` (worker) | worker, on deploy |

The values in `k8s/overlays/gcp` must match these names; `INSTANCE_PREFIX` there
is `name_prefix`. `scripts/validate-template.sh` checks that the overlay keeps
every bucket setting under `INSTANCE_PREFIX-eve-` and gives app buckets their
own prefix.

App buckets need `EVE_STORAGE_APP_BUCKET_PREFIX`. Without it the worker names
them after the org prefix, so IAM cannot tell them apart from org buckets.
Changing the app prefix renames every app bucket: the worker creates new,
empty buckets on the next deploy and the old ones keep their data. If apps
already have buckets, copy the data across first (the `storage_buckets` table
lists each bucket's `physical_name`).

## Access model

Eve's pods run code that Eve did not write: pipeline scripts in the worker
and agent code in the agent runtime. Each account therefore holds only what
its pods need.

| Account | Used by (KSA) | Grants |
|---|---|---|
| `<name_prefix>-eve-storage` | `eve-api`, `eve-worker`, `eve-orchestrator` | Storage permissions of `roles/storage.admin` except `*.setIamPolicy`, on `<name_prefix>-eve-*` only; `storage.buckets.create` on the project; bucket IAM read and write on `<name_prefix>-eve-app-*` only (public app buckets); `signBlob` on itself (signed URLs) |
| `<name_prefix>-eve-agents` | `eve-agent-runtime` | `roles/storage.objectViewer` on `<name_prefix>-eve-org-*` only (ingested files) |

The custom roles are named `<name_prefix>_eveStorageOperator`,
`<name_prefix>_eveBucketCreator` and `<name_prefix>_eveAppBucketPublisher` (hyphens
become underscores), so two instances can share a project. The operator role
copies its permissions from `roles/storage.admin` at plan time, so it follows
Google's changes to that role.

Neither account can read other buckets in the project, such as backups or
Terraform state, and neither can grant anyone access to Eve's org or internal
buckets.

## Keep Terraform state out of the instance project

The state holds the database password, and anyone who can write it can make
the next `terraform apply` act with the operator's credentials. Keep the state
bucket in a separate admin project that Eve's service accounts have no role
in. If it must live in the instance project, never name it
`<name_prefix>-eve-*`, because that name falls inside the platform account's
grant. See `../../backend.tf.example`.

## App object storage (`x-eve.object_store`)

Eve does not yet have a keyless app-storage mode on GCP. The `shared` mode
works with a GCS HMAC key, but every app gets the same long-lived key and can
read every other app's buckets, so this module does not provision it. The
template will wire a keyless mode once the platform ships one; the app-bucket
prefix and the app-bucket IAM grant above are already in place for it.

If you need `shared` mode before then:

1. Create a dedicated service account whose only grant is
   `roles/storage.objectAdmin` with the condition
   `resource.name.startsWith("projects/_/buckets/<name_prefix>-eve-app-")`.
2. Create its HMAC key with `gcloud storage hmac create`, outside Terraform so
   the secret never lands in state, and store it in a Secret only the worker
   reads.
3. Give the worker `EVE_APP_STORAGE_ENDPOINT=https://storage.googleapis.com`,
   `EVE_APP_STORAGE_REGION=auto`, and `EVE_APP_STORAGE_ACCESS_KEY_ID` /
   `EVE_APP_STORAGE_SECRET_ACCESS_KEY` from that Secret.

Never create the key for `<name_prefix>-eve-storage` or
`<name_prefix>-eve-agents`: every app would then hold that account's access.

## Upgrading from the project-wide `storage.admin` grant

Earlier versions of this module granted `roles/storage.admin` on the whole
project and bound `eve-agent-runtime` to the platform account. To upgrade:

1. Check that the GCP overlay's bucket settings are under
   `<name_prefix>-eve-` (the template's defaults are). Any other bucket loses
   access when the old grant goes.
2. Edit the overlay, but do not deploy it yet: point the `eve-agent-runtime`
   annotation at `<name_prefix>-eve-agents@<project>.iam.gserviceaccount.com`,
   add `EVE_STORAGE_APP_BUCKET_PREFIX` to the worker (see "Bucket names" if
   apps already have buckets), and add `EVE_DB_SNAPSHOT_BUCKET` to the api and
   orchestrator.
3. `terraform apply`. It creates the agent runtime account and the new
   roles, adds the scoped operator grant before it removes
   `roles/storage.admin` (the `moved` block turns this into a
   create-before-destroy replacement), and deletes the old
   `eve-agent-runtime` binding. IAM changes can take a minute or two to take
   effect.
4. Straight after, `./bin/eve-infra deploy`, then restart the agent runtime
   (`kubectl rollout restart statefulset/eve-agent-runtime -n eve`) so it
   picks up its new account. Between the apply and the restart, agent jobs
   cannot fetch `ingest://` resources; nothing else in the agent runtime
   uses GCS.
