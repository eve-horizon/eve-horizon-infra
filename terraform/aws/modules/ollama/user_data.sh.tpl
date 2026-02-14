#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Ollama GPU Host Bootstrap ==="

ASG_NAME="${asg_name}"
IDLE_TIMEOUT_MINUTES="${idle_timeout_minutes}"
REGION="${region}"
VOLUME_ID="${ollama_volume_id}"

# IMDSv2 token for metadata queries
IMDS_TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

echo "Instance: $INSTANCE_ID  Region: $REGION  ASG: $ASG_NAME"

# -----------------------------------------------------------------------------
# 1. System packages
# -----------------------------------------------------------------------------
apt-get update
apt-get install -y awscli jq

# -----------------------------------------------------------------------------
# 2. NVIDIA drivers (headless server, no X11)
# -----------------------------------------------------------------------------
echo "Installing NVIDIA drivers..."
apt-get install -y --no-install-recommends nvidia-headless-550-server nvidia-utils-550-server
modprobe nvidia
echo "GPU detected:"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# -----------------------------------------------------------------------------
# 3. Attach and mount persistent EBS volume
# -----------------------------------------------------------------------------
echo "Attaching EBS volume $VOLUME_ID..."
aws ec2 attach-volume \
  --volume-id "$VOLUME_ID" \
  --instance-id "$INSTANCE_ID" \
  --device /dev/sdf \
  --region "$REGION"

# Wait for device to appear. On Nitro instances with local NVMe (g5, g6, p4, etc.)
# the EBS volume may NOT be /dev/nvme1n1 (that could be instance store). Instead,
# match by serial number: AWS encodes the volume ID (without hyphens) as the NVMe
# serial number, visible via lsblk MODEL column.
echo "Waiting for block device..."
VOLUME_ID_STRIPPED=$(echo "$VOLUME_ID" | tr -d '-')
DEVICE=""
for i in $(seq 1 30); do
  # Find NVMe device whose serial matches our EBS volume ID
  for dev in /dev/nvme?n1; do
    [ -e "$dev" ] || continue
    SERIAL=$(lsblk -no SERIAL "$dev" 2>/dev/null | tr -d ' ')
    if [ "$SERIAL" = "$VOLUME_ID_STRIPPED" ]; then
      DEVICE="$dev"
      break 2
    fi
  done
  # Fallback for non-Nitro instances
  if [ -e /dev/xvdf ]; then
    DEVICE=/dev/xvdf
    break
  fi
  sleep 2
done

if [ -z "$DEVICE" ]; then
  echo "ERROR: EBS device $VOLUME_ID did not appear after 60s"
  echo "Available NVMe devices:"
  lsblk -o NAME,SIZE,SERIAL,MODEL /dev/nvme?n1 2>/dev/null || true
  exit 1
fi

echo "Device found: $DEVICE"
mkdir -p /data/ollama

# Format only if no filesystem exists
if ! blkid "$DEVICE" &>/dev/null; then
  echo "Formatting $DEVICE..."
  mkfs.ext4 "$DEVICE"
fi

mount "$DEVICE" /data/ollama
# Grow filesystem if volume was resized (no-op if already full size)
resize2fs "$DEVICE" 2>/dev/null || true
echo "Mounted $DEVICE at /data/ollama ($(df -h /data/ollama | awk 'NR==2{print $2}'))"

# -----------------------------------------------------------------------------
# 4. Install Ollama
# -----------------------------------------------------------------------------
echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# -----------------------------------------------------------------------------
# 5. Configure Ollama (bind to all interfaces, use EBS for models)
# -----------------------------------------------------------------------------
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'CONF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_MODELS=/data/ollama/models"
CONF

# Ollama runs as "ollama" user — grant ownership of model storage
chown -R ollama:ollama /data/ollama

systemctl daemon-reload
systemctl enable --now ollama

# Wait for Ollama to be ready
echo "Waiting for Ollama to start..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:11434/api/version &>/dev/null; then
    break
  fi
  sleep 2
done
echo "Ollama is ready: $(curl -s http://localhost:11434/api/version)"

# -----------------------------------------------------------------------------
# 6. Pre-pull default models via API (idempotent — skips if already cached on EBS)
# Uses the HTTP API instead of CLI to avoid $HOME requirement in newer Ollama versions.
# Pulls run synchronously — script blocks until each model is fully downloaded.
# -----------------------------------------------------------------------------
echo "Pre-pulling models (skips if cached)..."
curl -sf http://localhost:11434/api/pull -d '{"name":"llama3.3:70b-instruct-q4_K_M"}' | tail -1 || echo "WARNING: llama3.3 pull failed"
curl -sf http://localhost:11434/api/pull -d '{"name":"qwen2.5-coder:32b-instruct-q4_K_M"}' | tail -1 || echo "WARNING: qwen2.5-coder pull failed"

# -----------------------------------------------------------------------------
# 7. Idle auto-shutdown (checks every 5 min, shuts down after N min idle)
# Sets ASG desired=0 then halts, so the box stays off until next wake.
# Grace period = idle timeout + 15 min to allow time for first real request
# after boot (NVIDIA drivers + Ollama install + model pulls can take 15+ min).
# -----------------------------------------------------------------------------
GRACE_MINUTES=$(( IDLE_TIMEOUT_MINUTES + 15 ))

cat > /usr/local/bin/ollama-idle-check.sh <<SCRIPT
#!/bin/bash
# Skip shutdown if instance has been up less than the grace period
UPTIME_MIN=\$(awk '{print int(\$1/60)}' /proc/uptime)
if [ "\$UPTIME_MIN" -lt "$GRACE_MINUTES" ]; then
  echo "Instance up \$UPTIME_MIN min < $GRACE_MINUTES min grace period — skipping idle check"
  exit 0
fi

# Check for inference activity (generate/chat/embed requests, not health probes)
LAST_ACTIVITY=\$(journalctl -u ollama --since "$IDLE_TIMEOUT_MINUTES minutes ago" --no-pager -q 2>/dev/null | grep -cE "(generate|chat|embed|running)" || true)
if [ "\$LAST_ACTIVITY" -eq 0 ]; then
  echo "Ollama idle for $IDLE_TIMEOUT_MINUTES min — scaling ASG to 0 and shutting down"
  logger -t ollama-idle "Scaling ASG $ASG_NAME to 0 and shutting down"
  aws autoscaling update-auto-scaling-group \\
    --auto-scaling-group-name "$ASG_NAME" \\
    --desired-capacity 0 \\
    --region "$REGION" || true
  shutdown -h now
fi
SCRIPT
chmod +x /usr/local/bin/ollama-idle-check.sh

cat > /etc/systemd/system/ollama-idle.timer <<'TIMER'
[Unit]
Description=Check Ollama idle and shutdown

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/ollama-idle.service <<'SERVICE'
[Unit]
Description=Ollama idle shutdown check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ollama-idle-check.sh
SERVICE

systemctl daemon-reload
systemctl enable --now ollama-idle.timer

echo "=== Ollama GPU Host Bootstrap Complete ==="
