# Ollama GPU Module — First-Class Opt-In for Eve Deployments

**Date:** 2026-02-14
**Status:** Planned
**Scope:** This template repo (`eve-horizon/eve-horizon-infra`)

## Goal

Add an optional `modules/ollama/` Terraform module that any Eve Horizon
deployment can enable to get on-demand GPU inference via Ollama. The module
provisions a spot GPU instance behind an ASG (desired=0), auto-starts when
the Eve API needs inference, and auto-shuts down after idle timeout.

This is already running on the Incept5 staging deployment (`incept5-eve-infra`).
This plan upstreams it into the template so every Eve deployment gets it as
a first-class option.

## How It Works

```
User sends inference request
        |
Eve API detects target = unhealthy
        |
   +----+----+
   |         |
ASG desired=1    Return 503
(AWS SDK)    "GPU starting, retry in ~90s"
   |
Spot instance launches (~60s)
   |
Ollama starts, health probe marks target healthy
   |
Next request succeeds
   |
... serves requests ...
   |
Idle timeout (default 30 min)
   |
Instance sets ASG desired=0, shuts down
   |
Health probe marks target unhealthy (resting state)
```

**Cost:** Only pay for actual GPU time. EBS ($8/mo) is the only fixed cost.
Typical staging usage: $20-35/mo.

---

## What Needs to Change

### 1. New: `modules/ollama/` (copy from incept5-eve-infra)

The module already exists and is proven. Copy it as-is:

```
modules/ollama/
  main.tf          # Spot ASG (max 1, desired 0), EBS, SG, IAM, launch template
  variables.tf     # instance_type, volume_size, idle_timeout_minutes, etc.
  outputs.tf       # asg_name, asg_arn, volume_id, security_group_id
  user_data.sh.tpl # NVIDIA driver, Ollama, EBS mount, idle shutdown timer
```

**Source:** `incept5-eve-infra/terraform/aws/modules/ollama/`

No modifications needed — the module is already parameterized with
`name_prefix`, `vpc_id`, `subnet_id`, `k3s_security_group_id`, etc.

---

### 2. Edit: `modules/ec2/` — Add IAM instance profile + key pair output

The template's EC2 module currently has **no IAM instance profile** and
doesn't export `key_pair_name`. Both are needed for the ollama module:

- **IAM profile** lets k3s pods call AWS APIs (ASG wake).
- **Key pair name** is passed to the ollama module for SSH access.

#### `modules/ec2/variables.tf` — Add:

```hcl
variable "iam_instance_profile_name" {
  description = "IAM instance profile name to attach (optional)"
  type        = string
  default     = ""
}
```

#### `modules/ec2/main.tf` — Add to `aws_instance.main`:

```hcl
resource "aws_instance" "main" {
  # ... existing fields ...
  iam_instance_profile = var.iam_instance_profile_name != "" ? var.iam_instance_profile_name : null
}
```

#### `modules/ec2/outputs.tf` — Add:

```hcl
output "key_pair_name" {
  description = "Name of the SSH key pair (for use by other modules)"
  value       = aws_key_pair.main.key_name
}
```

---

### 3. Edit: `main.tf` — Add conditional ollama module + IAM

The ollama module and its IAM dependencies should only be created when
`ollama_enabled = true`.

#### IAM role + instance profile (always created, minimal cost)

The k3s node needs an IAM instance profile regardless of whether ollama is
enabled — it's good hygiene and other features may need it later. If we
want to keep the template minimal, we can make this conditional too, but
the cleaner approach is: always create a k3s IAM role, conditionally attach
the ollama wake policy.

**Recommended:** Always create the role (it's free), conditionally add the
ollama policy. This avoids the complexity of conditionally adding an
instance profile to the EC2 instance.

```hcl
# -----------------------------------------------------------------------------
# IAM — k3s Node Role
# Allows the k3s node (and its pods) to call AWS APIs.
# Always created (free). Policies are added by optional modules.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "k3s_node" {
  name = "${var.name_prefix}-k3s-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = { Name = "${var.name_prefix}-k3s-node-role" }
}

resource "aws_iam_instance_profile" "k3s_node" {
  name = "${var.name_prefix}-k3s-node-profile"
  role = aws_iam_role.k3s_node.name

  tags = { Name = "${var.name_prefix}-k3s-node-profile" }
}
```

Pass to EC2 module:

```hcl
module "ec2" {
  # ... existing fields ...
  iam_instance_profile_name = aws_iam_instance_profile.k3s_node.name
}
```

#### Ollama module (conditional)

```hcl
# -----------------------------------------------------------------------------
# Ollama GPU Host Module (optional)
# On-demand spot GPU instance running Ollama
# -----------------------------------------------------------------------------
module "ollama" {
  count  = var.ollama_enabled ? 1 : 0
  source = "./modules/ollama"

  name_prefix           = var.name_prefix
  vpc_id                = module.network.vpc_id
  subnet_id             = module.network.public_subnet_id
  k3s_security_group_id = module.security.ec2_security_group_id
  allowed_ssh_cidrs     = var.allowed_ssh_cidrs
  instance_type         = var.ollama_instance_type
  volume_size           = var.ollama_volume_size
  idle_timeout_minutes  = var.ollama_idle_timeout_minutes
  ssh_key_name          = module.ec2.key_pair_name
}

# IAM: let k3s node wake/query the Ollama ASG
resource "aws_iam_role_policy" "k3s_ollama_wake" {
  count = var.ollama_enabled ? 1 : 0
  name  = "${var.name_prefix}-k3s-ollama-wake"
  role  = aws_iam_role.k3s_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "autoscaling:UpdateAutoScalingGroup"
        Resource = module.ollama[0].asg_arn
      },
      {
        Effect   = "Allow"
        Action   = "autoscaling:DescribeAutoScalingGroups"
        Resource = "*"
      }
    ]
  })
}
```

---

### 4. Edit: `variables.tf` — Add ollama variables

```hcl
# -----------------------------------------------------------------------------
# Ollama GPU Host (optional)
# -----------------------------------------------------------------------------

variable "ollama_enabled" {
  description = "Enable the on-demand Ollama GPU host for platform inference"
  type        = bool
  default     = false
}

variable "ollama_instance_type" {
  description = "EC2 instance type for the Ollama GPU host (must have NVIDIA GPU)"
  type        = string
  default     = "g6.xlarge"
}

variable "ollama_volume_size" {
  description = "EBS volume size in GB for Ollama model storage"
  type        = number
  default     = 100
}

variable "ollama_idle_timeout_minutes" {
  description = "Minutes of inactivity before the GPU host auto-shuts down"
  type        = number
  default     = 30
}
```

---

### 5. Edit: `outputs.tf` — Add conditional ollama outputs

```hcl
output "ollama_asg_name" {
  description = "ASG name for the Ollama GPU host (set as EVE_OLLAMA_ASG_NAME)"
  value       = var.ollama_enabled ? module.ollama[0].asg_name : null
}
```

---

### 6. Edit: `terraform.tfvars.example` — Document ollama vars

Add a new section (commented out by default):

```hcl
# -----------------------------------------------------------------------------
# Ollama GPU Host (optional)
# Enable to provision an on-demand GPU instance for platform-managed inference.
# The GPU starts automatically on first inference request and stops after idle.
# Requires a GPU-capable instance type (g6.xlarge, g5.xlarge, etc.)
# -----------------------------------------------------------------------------

# ollama_enabled              = true
# ollama_instance_type        = "g6.xlarge"    # 1x L4, 24 GB VRAM
# ollama_volume_size          = 100            # GB for model weights
# ollama_idle_timeout_minutes = 30             # auto-stop after idle
```

---

### 7. Edit: `config/platform.yaml` — Add ollama section

```yaml
# -----------------------------------------------------------------------------
# Ollama GPU Inference (optional)
# -----------------------------------------------------------------------------

ollama:
  # Enable on-demand GPU inference via Ollama.
  # Provisions a spot GPU instance that starts automatically when the API
  # receives an inference request and stops after idle timeout.
  enabled: false                              # [OPTIONAL] Set true to enable

  # GPU instance type. Must be NVIDIA GPU-equipped.
  #   g6.xlarge  : 1x L4,  24 GB VRAM, ~$0.25/hr spot  (recommended)
  #   g5.xlarge  : 1x A10G, 24 GB VRAM, ~$0.30/hr spot
  #   g6.2xlarge : 1x L4,  24 GB VRAM, 8 vCPU, 32 GB RAM
  instance_type: g6.xlarge                    # [OPTIONAL]

  # Persistent disk for model weights (survives stop/start).
  disk_size_gb: 100                           # [OPTIONAL]

  # Auto-stop after this many minutes of no inference requests.
  idle_timeout_minutes: 30                    # [OPTIONAL]
```

---

### 8. Edit: `config/secrets.env.example` — Add ollama env vars

```bash
# -----------------------------------------------------------------------------
# Ollama GPU Inference  [REQUIRED when ollama.enabled=true]
# -----------------------------------------------------------------------------

# Base URL of the Ollama GPU host (private IP from Terraform output).
# Set automatically by the deploy workflow when ollama is enabled.
# EVE_OLLAMA_BASE_URL=http://10.0.x.x:11434

# ASG name for on-demand GPU wake (from Terraform output: ollama_asg_name).
# EVE_OLLAMA_ASG_NAME=
```

---

### 9. Edit: `DEPLOYMENT.md` or `README.md` — Add ollama section

Add a short section explaining how to enable GPU inference:

```markdown
## GPU Inference (optional)

Eve can provision an on-demand GPU instance for local LLM inference via Ollama.

1. Set `ollama_enabled = true` in your `terraform.tfvars`
2. Run `terraform apply`
3. Add the Terraform outputs to your Eve deployment:
   - `EVE_OLLAMA_BASE_URL` — from the GPU instance's private IP
   - `EVE_OLLAMA_ASG_NAME` — from `terraform output ollama_asg_name`
4. Redeploy Eve: the API auto-registers the GPU target on startup
5. Register models via CLI:
   ```bash
   eve ollama model add --canonical llama-3.3-70b --provider ollama --slug llama3.3:70b-instruct-q4_K_M
   ```

The GPU starts cold (no cost). When an inference request arrives, Eve wakes
the GPU (~90s), serves the request, and auto-stops after 30 minutes idle.
```

---

## File Change Summary

| File | Change |
|------|--------|
| `terraform/aws/modules/ollama/main.tf` | **New** — copy from incept5-eve-infra |
| `terraform/aws/modules/ollama/variables.tf` | **New** — copy from incept5-eve-infra |
| `terraform/aws/modules/ollama/outputs.tf` | **New** — copy from incept5-eve-infra |
| `terraform/aws/modules/ollama/user_data.sh.tpl` | **New** — copy from incept5-eve-infra |
| `terraform/aws/modules/ec2/main.tf` | **Edit** — add `iam_instance_profile` |
| `terraform/aws/modules/ec2/variables.tf` | **Edit** — add `iam_instance_profile_name` var |
| `terraform/aws/modules/ec2/outputs.tf` | **Edit** — add `key_pair_name` output |
| `terraform/aws/main.tf` | **Edit** — add IAM role, conditional ollama module + policy |
| `terraform/aws/variables.tf` | **Edit** — add `ollama_*` variables |
| `terraform/aws/outputs.tf` | **Edit** — add conditional `ollama_asg_name` |
| `terraform/aws/terraform.tfvars.example` | **Edit** — add commented ollama section |
| `config/platform.yaml` | **Edit** — add `ollama:` section |
| `config/secrets.env.example` | **Edit** — add ollama env vars |
| `README.md` or `DEPLOYMENT.md` | **Edit** — add GPU inference section |

## Sync Back to incept5-eve-infra

After the template is updated, `incept5-eve-infra` should be updated to match:

1. Replace the hardwired ollama module block with the conditional version
2. Set `ollama_enabled = true` in its `terraform.tfvars`
3. The IAM role / instance profile pattern should match the template

This is a non-breaking change — adding `count` to an existing module that's
already deployed requires a `terraform state mv` to avoid destroy/recreate:

```bash
terraform state mv 'module.ollama' 'module.ollama[0]'
terraform state mv 'aws_iam_role_policy.k3s_ollama_wake' 'aws_iam_role_policy.k3s_ollama_wake[0]'
```

## Open Decisions

1. **Always-create IAM role vs conditional**: Creating the k3s IAM role
   unconditionally is simpler and forward-compatible (other modules may need
   it). The role itself is free. Only the ollama wake policy is conditional.
   **Recommendation: always create.**

2. **Deploy workflow integration**: Should the deploy workflow auto-discover
   the ollama private IP and set `EVE_OLLAMA_BASE_URL`? This would require
   adding an AWS CLI step to the deploy workflow. Alternative: use a static
   ENI or require manual configuration. **Recommendation: manual for now,
   auto-discovery later.**

3. **Model pre-pull list**: The user_data currently hardcodes `llama3.3:70b`
   and `qwen2.5-coder:32b`. Should this be configurable via a Terraform
   variable (`ollama_default_models`)? **Recommendation: add the variable
   but keep the current defaults.**
