#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/ollama-startup.log) 2>&1

echo "=== Ollama GPU Host Bootstrap (GCP) ==="

DISK_NAME="${disk_name}"
MIG_NAME="${mig_name}"
ZONE="${zone}"
IDLE_TIMEOUT_MINUTES="${idle_timeout_minutes}"

# -----------------------------------------------------------------------------
# 1. NVIDIA drivers (headless server, no X11)
# -----------------------------------------------------------------------------
echo "Installing NVIDIA drivers..."
apt-get update
apt-get install -y --no-install-recommends nvidia-headless-550-server nvidia-utils-550-server
modprobe nvidia
echo "GPU detected:"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# -----------------------------------------------------------------------------
# 2. Attach and mount persistent disk
# -----------------------------------------------------------------------------
echo "Attaching persistent disk $DISK_NAME..."
DEVICE="/dev/disk/by-id/google-$DISK_NAME"

# Wait for device to appear
for i in $(seq 1 30); do
  [ -e "$DEVICE" ] && break
  sleep 2
done

if [ ! -e "$DEVICE" ]; then
  echo "ERROR: Disk device $DEVICE did not appear after 60s"
  ls -la /dev/disk/by-id/ || true
  exit 1
fi

mkdir -p /data/ollama

# Format only if no filesystem exists
if ! blkid "$DEVICE" &>/dev/null; then
  echo "Formatting $DEVICE..."
  mkfs.ext4 -L ollama-models "$DEVICE"
fi

mount "$DEVICE" /data/ollama
resize2fs "$DEVICE" 2>/dev/null || true
echo "Mounted $DEVICE at /data/ollama ($(df -h /data/ollama | awk 'NR==2{print $2}'))"

# -----------------------------------------------------------------------------
# 3. Install Ollama
# -----------------------------------------------------------------------------
echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# -----------------------------------------------------------------------------
# 4. Configure Ollama (bind to all interfaces, use persistent disk for models)
# -----------------------------------------------------------------------------
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'CONF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_MODELS=/data/ollama/models"
CONF

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
# 5. Pre-pull default models via API (idempotent — skips if cached on disk)
# -----------------------------------------------------------------------------
echo "Pre-pulling models (skips if cached)..."
curl -sf http://localhost:11434/api/pull -d '{"name":"llama3.3:70b-instruct-q4_K_M"}' | tail -1 || echo "WARNING: llama3.3 pull failed"
curl -sf http://localhost:11434/api/pull -d '{"name":"qwen2.5-coder:32b-instruct-q4_K_M"}' | tail -1 || echo "WARNING: qwen2.5-coder pull failed"

# -----------------------------------------------------------------------------
# 6. Idle auto-shutdown
# Sets MIG target_size=0 then halts, so the box stays off until next wake.
# Grace period = idle timeout + 15 min to allow time for boot + model pulls.
# -----------------------------------------------------------------------------
GRACE_MINUTES=$(( IDLE_TIMEOUT_MINUTES + 15 ))

cat > /usr/local/bin/ollama-idle-check.sh <<SCRIPT
#!/bin/bash
# Skip shutdown if instance has been up less than the grace period
UPTIME_MIN=\$(awk '{print int(\$1/60)}' /proc/uptime)
if [ "\$UPTIME_MIN" -lt "$GRACE_MINUTES" ]; then
  echo "Instance up \$UPTIME_MIN min < $GRACE_MINUTES min grace period -- skipping idle check"
  exit 0
fi

# Check for inference activity
LAST_ACTIVITY=\$(journalctl -u ollama --since "$IDLE_TIMEOUT_MINUTES minutes ago" --no-pager -q 2>/dev/null | grep -cE "(generate|chat|embed|running)" || true)
if [ "\$LAST_ACTIVITY" -eq 0 ]; then
  echo "Ollama idle for $IDLE_TIMEOUT_MINUTES min -- resizing MIG to 0 and shutting down"
  logger -t ollama-idle "Resizing MIG $MIG_NAME to 0 and shutting down"
  gcloud compute instance-groups managed resize "$MIG_NAME" \\
    --size=0 --zone="$ZONE" --quiet || true
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
