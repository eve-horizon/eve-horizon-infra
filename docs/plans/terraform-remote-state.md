# Terraform Remote State Migration — S3 + DynamoDB

**Date:** 2026-02-27
**Status:** Draft (Terraform-only)
**Scope:** Migrate local tfstate to S3 backend with locking; enable multi-operator terraform

## Problem

Terraform state currently lives on a single developer machine (`terraform/aws/terraform.tfstate`).
This creates three hard problems:

1. **Bus factor = 1** — only the person holding the state file can plan/apply
2. **No locking** — if two people run terraform concurrently, state corruption is possible
3. **No audit trail** — state changes are invisible; accidental `rm` or disk loss means rebuild from scratch

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  AWS Account 767828750268 — eu-west-1                           │
│                                                                  │
│  ┌───────────────────────────┐   ┌──────────────────────────┐   │
│  │ S3: eh1-terraform-state-… │   │ DynamoDB: eh1-tf-lock    │   │
│  │ ├── env:/staging/         │   │ LockID (partition key)   │   │
│  │ │   terraform.tfstate     │   │                          │   │
│  │ ├── Versioning: Enabled   │   │ On-demand billing        │   │
│  │ ├── Encryption: AES-256   │   │ ~$0/mo (negligible)      │   │
│  │ └── Public: Blocked       │   └──────────────────────────┘   │
│  └───────────────────────────┘                                   │
│                                                                  │
│  Operator A ──┐                                                  │
│  Operator B ──┤── terraform init/plan/apply ──▶ S3 state         │
│  CI/CD     ──┘       (DynamoDB lock held)                        │
└─────────────────────────────────────────────────────────────────┘
```

## Why S3 + DynamoDB (not Terraform Cloud, not HCP)

| Option | Verdict | Reason |
|--------|---------|--------|
| **S3 + DynamoDB** | **Chosen** | Zero vendor lock-in, cost-effective at this scale, native to our AWS account |
| Terraform Cloud | Rejected | External dependency and policy coupling for a small staging environment |
| HCP Terraform | Rejected | Overkill for current scope; paid features not yet needed |
| Consul | Rejected | More infra to operate for a single state backend need |

## Implementation Plan

### Phase 1: Bootstrap the Backend Resources (Terraform-only)

Out-of-band AWS CLI mutations are explicitly prohibited by repo rules. Create backend resources via a dedicated Terraform root.

Create `terraform/aws-backend/main.tf`:

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Bootstrap root intentionally uses local state — it only manages the
  # backend bucket and lock table, not the infrastructure itself.
  backend "local" {}
}

provider "aws" {
  region = "eu-west-1"
}

resource "aws_s3_bucket" "tf_state" {
  bucket = "eh1-terraform-state-767828750268"
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "eh1-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

Create `terraform/aws-backend/outputs.tf`:

```hcl
output "state_bucket" {
  value = aws_s3_bucket.tf_state.id
}

output "lock_table" {
  value = aws_dynamodb_table.tf_lock.name
}
```

Commands:

```bash
cd terraform/aws-backend
terraform init
terraform plan
terraform apply
```

The root `.gitignore` patterns (`*.tfstate`, `.terraform/`) already cover this directory — no additional `.gitignore` needed.

### Phase 2: Add Backend Configuration

Add the `backend "s3"` block inside the existing `terraform {}` block in `terraform/aws/providers.tf`. The rest of the file (provider block with `default_tags`, `local.effective_region`, etc.) stays unchanged:

```hcl
terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket         = "eh1-terraform-state-767828750268"
    key            = "env/staging/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "eh1-tf-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# provider "aws" { ... } block remains unchanged
```

The `key` uses `env/staging/` prefix to allow future environments (production, dev) in the same bucket without collision.

> **Note:** Backend blocks cannot use variables or locals — all values must be literal strings.

### Phase 3: Migrate State

This is the critical step. Terraform handles it natively:

```bash
cd terraform/aws

# Terraform detects the backend change and offers to copy existing state to S3.
# IMPORTANT: use -migrate-state (NOT -reconfigure — they are mutually exclusive).
# -migrate-state = copy state to new backend
# -reconfigure   = forget old backend, start fresh (would LOSE state)
terraform init -migrate-state

# Answer "yes" when prompted to copy state to the new S3 backend.

# Verify:
#   - "Successfully configured the backend"
#   - terraform plan shows NO changes (state is identical)
terraform plan
```

### What happens under the hood:
1. Terraform reads the local `terraform.tfstate`
2. Uploads it to `s3://eh1-terraform-state-767828750268/env/staging/terraform.tfstate`
3. Acquires a DynamoDB lock during the upload
4. Writes a local backup (`terraform.tfstate.backup`), then updates `.terraform/terraform.tfstate` to track the new backend

### Phase 4: Clean Up

```bash
# 1. Copy state to a safe location OUTSIDE the repo first
cp terraform/aws/terraform.tfstate ~/eh1-terraform-state-backup-$(date +%Y%m%d).json

# 2. Verify remote state is working BEFORE deleting local copies
cd terraform/aws
terraform plan   # Should show no changes — state is now served from S3

# 3. Only after verifying, remove local state files (already gitignored)
rm -f terraform.tfstate terraform.tfstate.backup
```

### Phase 5: Secure Multi-Operator Access

Each operator needs AWS credentials with permission to:
- Read/write the S3 state bucket
- Read/write the DynamoDB lock table
- Manage the actual infrastructure (existing permissions)

**IAM policy for state access:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::eh1-terraform-state-767828750268",
        "arn:aws:s3:::eh1-terraform-state-767828750268/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
        "dynamodb:DescribeTable"
      ],
      "Resource": "arn:aws:dynamodb:eu-west-1:767828750268:table/eh1-tf-lock"
    }
  ]
}
```

This can be attached to an IAM group (e.g., `eh1-terraform-operators`) so onboarding a new operator is: create IAM user, add to group, share secrets file.

### Phase 6: Commit Lock File for Provider Consistency

`.terraform.lock.hcl` is currently gitignored. With multiple operators, each running `terraform init` independently may resolve different provider builds. Remove it from `.gitignore` and commit it:

```bash
# Remove the gitignore rule for .terraform.lock.hcl
# Then:
cd terraform/aws
terraform init    # generates/updates lock file
git add .terraform.lock.hcl
```

This ensures all operators use identical provider checksums.

### Phase 7: Onboard Second Operator

After the migration is committed and pushed, a new operator does:

```bash
git clone <repo>
cd terraform/aws

# Configure AWS credentials (must have state bucket + lock table access)
# Copy secrets.auto.tfvars (contains db_password) from secure channel

# Initialize — -reconfigure tells Terraform to adopt the remote backend
# without attempting to migrate any local state (there is none)
terraform init -reconfigure

terraform plan   # Should work against remote state with DynamoDB locking
```

## Sensitive Data: secrets.auto.tfvars

Secrets are split from configuration: `terraform.tfvars` is committed to git (non-sensitive config), while `secrets.auto.tfvars` (gitignored) contains `db_password` and is loaded automatically by Terraform.

Each operator needs a copy of `secrets.auto.tfvars`. Options for distributing it:

| Approach | Complexity | Recommendation |
|----------|------------|----------------|
| Copy via secure channel (1Password, encrypted email) | Low | **Current approach** — simple for small team |
| `TF_VAR_db_password` env var | Low | Good alternative; avoids plaintext files entirely |
| AWS Secrets Manager + `data "aws_secretsmanager_secret"` | Medium | Best long-term for operations and CI |
| SOPS-encrypted tfvars committed to git | Medium | Enables gitops; requires GPG/KMS setup |

## Cost

| Resource | Monthly Cost |
|----------|-------------|
| S3 bucket (versioned, <1 MB state) | ~$0.01 |
| DynamoDB table (on-demand, ~10 ops/day) | ~$0.00 |
| **Total** | **~$0.01/mo** |

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| State migration corrupts state | Take a local backup of `terraform.tfstate` before migration. S3 versioning enables rollback. |
| Operator accidentally deletes S3 bucket | Bucket versioning + lifecycle rules; enforce deletion guardrails in IAM |
| Lock stuck after crashed apply | `terraform force-unlock <LOCK_ID>` after confirming no active owner |
| Lost access to AWS account | Standard AWS account recovery; S3 versioning preserves history |

## Execution Checklist

```
[ ] 1. Back up local terraform.tfstate to a safe location OUTSIDE the repo
[ ] 2. Create terraform/aws-backend/ with main.tf and outputs.tf
[ ] 3. Run terraform/aws-backend init/plan/apply to create S3 bucket + DynamoDB table
[ ] 4. Add backend "s3" block to terraform/aws/providers.tf
[ ] 5. Run terraform init -migrate-state (answer "yes" to copy state)
[ ] 6. Verify terraform plan shows no changes
[ ] 7. Delete local terraform.tfstate and .backup files
[ ] 8. Verify terraform plan still shows no changes (reading from S3)
[ ] 9. Remove .terraform.lock.hcl from .gitignore
[ ] 10. Commit providers.tf, backend root, and .terraform.lock.hcl
[ ] 11. Push to remote
[ ] 12. Second operator: clone, add AWS creds + secrets.auto.tfvars, terraform init -reconfigure, terraform plan
```

## Future Considerations

- **Production environment**: Same bucket, different key prefix (`env/production/`)
- **CI/CD integration**: GitHub Actions with OIDC federation to AWS (no long-lived keys)
- **State encryption**: Currently AES-256 (S3 managed key). Can upgrade to KMS CMK if needed
- **Workspaces**: Not using terraform workspaces — separate key prefixes are simpler and prevent accidental cross-env operations
- **Bootstrap state**: The `terraform/aws-backend/` root uses local state. If this becomes a concern, it can self-migrate to its own S3 key — but for two resources this is overkill
