#!/bin/bash
# Container entrypoint for the dsh QEMU VM; the layering follows
# Compiler-Security/CompilerExplorer-Deploy (thin QEMU runtime image, base
# cloud image downloaded on first boot, cloud-init-provisioned qcow2 overlay).
#
# Read-only 9p shares exported into the guest:
#   /opt/dsh      -> mount_tag dsh     the dsh npm tree (always exported)
#   /share/config -> mount_tag config  optional; overlayfs lowerdir for the
#                                      guest dsh home, so the host directory
#                                      is never written
#   /share/skills -> mount_tag skills  optional; linked into ~/.agents/skills
#
# Ports: guest web 10240 and guest ssh 22 forward to the same container ports;
# SSH uses ${DSH_VM_SSH_PORT:-2222}. `--selftest` verifies the image without
# booting the guest (CI runs it; hosted runners have no /dev/kvm).
set -euo pipefail

DISK_DIR=/vm/disk
SEED_DIR=$DISK_DIR/seed
DSH_VERSION=${DSH_VERSION:-unknown}
SSH_PORT=${DSH_VM_SSH_PORT:-2222}
WEB_PORT=${DSH_VM_WEB_PORT:-10240}
VM_CPUS=${DSH_VM_CPUS:-4}
VM_MEMORY_MB=${DSH_VM_MEMORY_MB:-4096}
VM_DISK_GB=${DSH_VM_DISK_GB:-40}
# Pin a dated Ubuntu cloud release in production via VM_IMAGE_URL plus
# VM_IMAGE_SHA256; the default tracks noble/current and records (not enforces)
# the hash it observed at download time.
VM_IMAGE_URL=${VM_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}
BASE_IMG=$DISK_DIR/base.img
BASE_SHA_FILE=$DISK_DIR/base.sha256
OVERLAY_IMG=$DISK_DIR/dsh-vm.qcow2
PROVISION_ID_FILE=$DISK_DIR/provision.id
MONITOR_SOCK=$DISK_DIR/monitor.sock
SSH_KEY_PATH=$DISK_DIR/ssh/id_ed25519

# Everything logged goes to stderr: resolve_ssh_pubkey and render_env_file run
# under command substitution, and a stdout log line would corrupt their output.
log() { echo "[dsh-vm] $*" >&2; }
die() { echo "[dsh-vm] ERROR: $*" >&2; exit 1; }

selftest() {
  local tool
  for tool in qemu-system-x86_64 qemu-img genisoimage socat ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || die "selftest: missing $tool"
  done
  [ -x /opt/dsh/bin/dsh ] || die 'selftest: /opt/dsh/bin/dsh missing; the npm tree did not install'
  [ -f /opt/dsh/lib/node_modules/@deepseek-ai/dsh/lib/bin.js ] \
    || die 'selftest: @deepseek-ai/dsh/lib/bin.js missing from the installed tree'
  grep -q '__SSH_PUBKEY__' /vm/user-data || die 'selftest: user-data template lost its placeholders'
  [ -f /vm/meta-data ] || die 'selftest: meta-data missing'
  grep -q 'dsh.service' /vm/user-data || die 'selftest: user-data no longer installs dsh.service'
  log "selftest passed: qemu toolchain + dsh npm tree intact"
  exit 0
}

# Resolve the management SSH public key: from the private key named by
# DSH_VM_SSH_KEY, or the keypair generated into the disk volume on first boot.
resolve_ssh_pubkey() {
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  local pub
  if [ -n "${DSH_VM_SSH_KEY:-}" ]; then
    [ -f "$DSH_VM_SSH_KEY" ] || die "DSH_VM_SSH_KEY=$DSH_VM_SSH_KEY is not a file"
    pub=$(ssh-keygen -y -f "$DSH_VM_SSH_KEY")
  else
    if [ ! -f "$SSH_KEY_PATH" ]; then
      ssh-keygen -t ed25519 -N '' -f "$SSH_KEY_PATH" -q
      log "generated management keypair $SSH_KEY_PATH; copy the private key out to connect"
    fi
    pub=$(ssh-keygen -y -f "$SSH_KEY_PATH")
  fi
  echo "$pub" | grep -Eq '^(ssh-(rsa|dss|ed25519)|ecdsa-[a-z0-9-]+|[A-Za-z0-9-]+- certificate) [A-Za-z0-9+/=]+' \
    || die "resolved SSH public key does not look like a public key: $pub"
  echo "$pub"
}

# Render /etc/dsh.env for the guest service; always non-empty so the
# EnvironmentFile check cannot fail on a fresh boot without credentials.
render_env_file() {
  local tmp=$DISK_DIR/dsh.env
  printf '# dsh guest environment\n' > "$tmp"
  local key
  for key in DEEPSEEK_API_KEY DEEPSEEK_BASE_URL DSH_TELEMETRY_DISABLED; do
    [ -n "${!key:-}" ] && printf '%s=%s\n' "$key" "${!key}" >> "$tmp"
  done
  grep -q '^DEEPSEEK_API_KEY=' "$tmp" \
    || log 'WARNING: DEEPSEEK_API_KEY is not set; the web UI boots without model access'
  chmod 600 "$tmp"
  base64 -w0 "$tmp"
}

# The fingerprint covers every guest-visible input plus the base image hash;
# any change discards the overlay and forces clean reprovisioning.
provision_input_id() {
  {
    cat /vm/user-data /vm/meta-data /vm/dsh.service
    echo "dsh-version=$DSH_VERSION"
    cat "$BASE_SHA_FILE"
  } | sha256sum | cut -d' ' -f1
}

ensure_base_image() {
  local expected=${VM_IMAGE_SHA256:-}
  if [ -f "$BASE_IMG" ] && [ -f "$BASE_SHA_FILE" ] \
    && { [ -z "$expected" ] || [ "$expected" = "$(cat "$BASE_SHA_FILE")" ]; }; then
    return 0
  fi
  log "downloading base image $VM_IMAGE_URL"
  mkdir -p "$DISK_DIR"
  curl -fL --retry 3 -o "$BASE_IMG.partial" "$VM_IMAGE_URL"
  local actual
  actual=$(sha256sum "$BASE_IMG.partial" | cut -d' ' -f1)
  if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
    rm -f "$BASE_IMG.partial"
    die "base image sha256 mismatch: expected $expected, got $actual"
  fi
  echo "$actual" > "$BASE_SHA_FILE"
  mv "$BASE_IMG.partial" "$BASE_IMG"
  [ -n "$expected" ] || log "recorded base image sha256 $actual (set VM_IMAGE_SHA256 to enforce it)"
}

prepare_overlay() {
  local want_id fresh=0
  want_id=$(provision_input_id)
  if [ "${FORCE_REPROVISION:-0}" = "1" ]; then
    rm -f "$OVERLAY_IMG" "$PROVISION_ID_FILE"
    log 'FORCE_REPROVISION=1: discarded the provisioned overlay'
  elif [ -f "$OVERLAY_IMG" ] && [ -f "$PROVISION_ID_FILE" ] \
    && [ "$(cat "$PROVISION_ID_FILE")" != "$want_id" ]; then
    rm -f "$OVERLAY_IMG"
    log 'provision inputs changed: discarded the stale overlay for clean reprovisioning'
  fi
  if [ ! -f "$OVERLAY_IMG" ]; then
    fresh=1
    qemu-img create -q -f qcow2 -b "$BASE_IMG" -F qcow2 "$OVERLAY_IMG" "${VM_DISK_GB}G"
    log "created overlay disk (${VM_DISK_GB}G)"
  fi
  echo "$fresh"
}

render_seed() {
  local pub=$1 fresh=$2
  local env_b64 svc_b64 esc_pub
  env_b64=$(render_env_file)
  svc_b64=$(base64 -w0 /vm/dsh.service)
  esc_pub=$(printf '%s' "$pub" | sed -e 's/[&\]/\\&/g')
  mkdir -p "$SEED_DIR"
  awk -v pub="$esc_pub" -v ver="$DSH_VERSION" -v env="$env_b64" -v svc="$svc_b64" '
    { gsub(/__SSH_PUBKEY__/, pub); gsub(/__DSH_VERSION__/, ver)
      gsub(/__DSH_ENV_B64__/, env); gsub(/__DSH_SERVICE_B64__/, svc); print }
  ' /vm/user-data > "$SEED_DIR/user-data"
  cp /vm/meta-data "$SEED_DIR/meta-data"
  genisoimage -quiet -output "$SEED_DIR/seed.iso" -volid cidata -joliet -rock \
    "$SEED_DIR/user-data" "$SEED_DIR/meta-data"
}

# Wait for the guest web service; any HTTP response counts (the web UI answers
# 401 to unauthenticated probes). The provisioning fingerprint is written only
# on success so a failed provision retries cleanly on the next boot.
await_web() {
  local fresh=$1 i
  [ "$fresh" = "1" ] || return 0
  log 'waiting for first-boot provisioning (web on 10240); under TCG this takes a while'
  for i in $(seq 1 360); do
    if curl -s -o /dev/null --max-time 5 "http://127.0.0.1:${WEB_PORT}"; then
      echo "$(provision_input_id)" > "$PROVISION_ID_FILE"
      log "guest provisioned and serving after ~$((i * 5))s"
      return 0
    fi
    sleep 5
  done
  log 'WARNING: web did not come up within 30 minutes; keeping the guest running for SSH debugging'
}

shutdown_trap() {
  log 'shutting the guest down (ACPI powerdown)'
  if [ -S "$MONITOR_SOCK" ]; then
    echo system_powerdown | socat - "unix-connect:$MONITOR_SOCK" 2>/dev/null || true
  fi
  local i
  for i in $(seq 1 60); do
    kill -0 "$QEMU_PID" 2>/dev/null || exit 0
    sleep 1
  done
  log 'guest did not power down within 60s; killing'
  kill "$QEMU_PID" 2>/dev/null || true
}

QEMU_PID=0
main() {
  [ "${1:-}" = "--selftest" ] && selftest
  [ "$(id -u)" = "0" ] || die 'must run as root (qemu + disk volume access)'
  command -v findmnt >/dev/null 2>&1 || die 'findmnt missing; cannot detect mounted shares'

  mkdir -p "$DISK_DIR"
  ensure_base_image
  local pub fresh
  pub=$(resolve_ssh_pubkey)
  fresh=$(prepare_overlay)
  render_seed "$pub" "$fresh"

  local accel cpu
  if [ -c /dev/kvm ] && [ -w /dev/kvm ]; then
    accel=kvm cpu=host
  else
    accel=tcg cpu=max
    log 'no usable /dev/kvm: running under TCG emulation (slow; provisioning may take 20+ minutes)'
  fi

  local -a qemu=(
    qemu-system-x86_64 -machine q35 -accel "$accel" -cpu "$cpu"
    -smp "$VM_CPUS" -m "$VM_MEMORY_MB"
    -drive "file=$OVERLAY_IMG,if=virtio,format=qcow2"
    -drive "file=$SEED_DIR/seed.iso,if=virtio,format=raw,media=cdrom"
    -device virtio-rng-pci
    -netdev "user,id=net0,hostfwd=tcp::${WEB_PORT}-:10240,hostfwd=tcp::${SSH_PORT}-:22"
    -device virtio-net-pci,netdev=net0
    -virtfs "local,id=dsh,mount_tag=dsh,path=/opt/dsh,security_model=none,readonly=on"
    -display none -serial stdio
    -monitor "unix:$MONITOR_SOCK,server,nowait"
    -pidfile "$DISK_DIR/qemu.pid"
    -name dsh-vm
  )
  if findmnt --target /share/config >/dev/null 2>&1; then
    qemu+=(-virtfs "local,id=config,mount_tag=config,path=/share/config,security_model=none,readonly=on")
  else
    log 'no /share/config mount: guest starts with an empty dsh home'
  fi
  if findmnt --target /share/skills >/dev/null 2>&1; then
    qemu+=(-virtfs "local,id=skills,mount_tag=skills,path=/share/skills,security_model=none,readonly=on")
  else
    log 'no /share/skills mount: guest starts without extra skills'
  fi
  log "booting guest (accel=$accel, cpus=$VM_CPUS, mem=${VM_MEMORY_MB}MB); web :$WEB_PORT, ssh :$SSH_PORT"

  trap shutdown_trap TERM INT
  "${qemu[@]}" &
  QEMU_PID=$!
  await_web "$fresh" &
  AWAIT_PID=$!
  wait "$QEMU_PID"
}

main "$@"
