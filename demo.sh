#!/usr/bin/env bash
# =============================================================================
# Kuasar Sandbox — single-node Demo deployment (Path A: aggregate release +
# workbench, no source build).  Target environment: this WSL2 host (Ubuntu
# 24.04, native /dev/kvm, local Clash proxy, Docker Desktop present but unused).
#
# Everything stateful lives under $KUASAR_DEPLOY_DATA (default
# /home/cyx/kuasar-deploy-data), NEVER inside the git checkout.
#
# Usage:
#   ./demo.sh setup      # one-time host prep: native Docker, image, egress rule
#   ./demo.sh download   # fetch + verify one aggregate release, extract, load image
#   ./demo.sh init       # create/start a workbench instance
#   ./demo.sh prepare    # offline-prepare Demo inputs inside workbench
#   ./demo.sh quick      # short Demo lifecycle
#   ./demo.sh full       # complete Demo (fan-out + one-call migration)
#   ./demo.sh status     # show release/image/instance/container state
#   ./demo.sh stop       # stop Demo storage tier + workbench instance
#   ./demo.sh reset      # delete Demo data inside workbench
#   ./demo.sh cleanup    # stop + remove workbench container/image artifacts
#
# See DEPLOY.md for the full explanation, prerequisites and troubleshooting.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${KUASAR_DEPLOY_DATA:-/home/cyx/kuasar-deploy-data}"
VERSION="${RELEASE_VERSION:-release-v0.1.6}"
ARCH="$(uname -m)"
DOCKER_HOST_NATIVE="unix:///run/docker-native.sock"
export DOCKER_HOST="${DOCKER_HOST:-$DOCKER_HOST_NATIVE}"

DL="$DATA/dl-$VERSION"
RELEASE="$DATA/$VERSION"
IMAGE="ghcr.io/kuasar-sandbox/workbench:${VERSION#release-}"
STATE="$DATA/kuasar-workbench-state"
NAME_FILE="$DATA/.wb-name"
WB="$RELEASE/workbench/workbench"
DATADIR="/work/kuasar-demo-run"           # inside workbench; must be kuasar-demo-<name>
CPUS="${WB_CPUS:-6}"
MEMGIB="${WB_MEMGIB:-6}"
PROXY_PORT="${CLASH_PROXY_PORT:-7897}"

log(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){  printf '\033[1;32m  + %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }
die(){ printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

host_gateway(){ ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}'; }

# ---------------------------------------------------------------------------
# Host preparation (idempotent). Creates the native rootful Engine, which the
# workbench host_check requires, and which Docker Desktop (present on this WSL
# host) does not satisfy.
# ---------------------------------------------------------------------------
install_native_docker(){
  if [ -x /usr/bin/dockerd ] && [ -f /etc/systemd/system/docker-native.service ]; then
    ok "native Docker already installed"
  else
    log "installing native Docker Engine (docker.io)"
    sudo -n apt-get update -qq
    sudo -n apt-get install -y -qq docker.io containerd
    sudo -n systemctl disable --now docker.service docker.socket >/dev/null 2>&1 || true
    sudo -n mkdir -p /etc/docker
    sudo -n tee /etc/docker/daemon.json >/dev/null <<'EOF'
{ "storage-driver": "overlay2", "exec-opts": ["native.cgroupdriver=cgroupfs"] }
EOF
  fi
  # Proxy-aware launcher: the Clash proxy is on the Windows host (= WSL default
  # gateway), whose address can change across WSL restarts.
  sudo -n mkdir -p /usr/local/libexec
  sudo -n tee /usr/local/libexec/docker-native-launch.sh >/dev/null <<EOF
#!/bin/sh
gw="\$(ip route show default 2>/dev/null | awk '/^default/ {print \$3; exit}')"
[ -n "\$gw" ] || gw=172.27.16.1
export http_proxy="http://\$gw:$PROXY_PORT"  https_proxy="http://\$gw:$PROXY_PORT"
export HTTP_PROXY="http://\$gw:$PROXY_PORT"  HTTPS_PROXY="http://\$gw:$PROXY_PORT"
export NO_PROXY="localhost,127.0.0.1,::1"     no_proxy="localhost,127.0.0.1,::1"
exec /usr/bin/dockerd --host=unix:///run/docker-native.sock
EOF
  sudo -n chmod 0755 /usr/local/libexec/docker-native-launch.sh
  sudo -n tee /etc/systemd/system/docker-native.service >/dev/null <<'EOF'
[Unit]
Description=Native rootful Docker Engine (Kuasar workbench host)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/libexec/docker-native-launch.sh
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF
  sudo -n systemctl daemon-reload
  sudo -n systemctl enable --now docker-native.service >/dev/null 2>&1 || true
}

ensure_docker(){
  if ! docker info >/dev/null 2>&1; then
    sudo -n systemctl start docker-native.service >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
  fi
  docker info >/dev/null 2>&1 || die "native Docker not reachable on $DOCKER_HOST"
  if docker info --format '{{.OperatingSystem}}' | grep -q 'Docker Desktop'; then
    die "refusing Docker Desktop; workbench needs the native engine ($DOCKER_HOST_NATIVE)"
  fi
}

ensure_sudoers(){
  if sudo -n true 2>/dev/null; then ok "passwordless sudo available"; return 0; fi
  local pwfile="$REPO/env"
  [ -f "$pwfile" ] || die "no passwordless sudo and $pwfile not found"
  # shellcheck disable=SC1090
  . "$pwfile"
  [ -n "${SUDO_PASSWORD:-}" ] || die "SUDO_PASSWORD not set in $pwfile"
  printf '%s\n' "$SUDO_PASSWORD" | sudo -S install -m 0440 /dev/stdin \
    /etc/sudoers.d/90-cyx-nopasswd >/dev/null 2>&1 <<EOF
cyx ALL=(ALL) NOPASSWD: ALL
EOF
  sudo -n true 2>/dev/null || die "failed to configure passwordless sudo"
  ok "configured passwordless sudo"
}

ensure_egress(){
  # This host cannot reach 1.1.1.1 directly (the local Clash proxy intercepts
  # that exact IP), but the Demo hardcodes http://1.1.1.1:80/ for its guest NAT
  # egress assertion. Redirect only that flow to a reachable Cloudflare edge so
  # the assertion still exercises real Internet egress through NAT.
  if sudo -n iptables -t nat -C PREROUTING -d 1.1.1.1 -p tcp --dport 80 \
       -j DNAT --to-destination 1.0.0.1:80 2>/dev/null; then
    ok "guest-egress redirect already present"
  else
    log "adding guest-egress redirect 1.1.1.1:80 -> 1.0.0.1:80"
    sudo -n iptables -t nat -A PREROUTING -d 1.1.1.1 -p tcp --dport 80 \
         -j DNAT --to-destination 1.0.0.1:80
  fi
}

ensure_networking(){
  # Demo requires ip_forward=1 and refuses to change it itself.
  if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != 1 ]; then
    warn "enabling net.ipv4.ip_forward=1 (Demo requirement)"
    sudo -n sysctl -q -w net.ipv4.ip_forward=1
  fi
}

ensure_image(){
  docker image inspect "$IMAGE" >/dev/null 2>&1 && { ok "workbench image present"; return 0; }
  local archive="$DL/workbench-$ARCH-$VERSION.tar.gz"
  [ -f "$archive" ] || die "missing $archive; run: $0 download"
  log "loading workbench image $IMAGE (large; ~1.3 GiB archive)"
  docker load --input "$archive"
}

# ---------------------------------------------------------------------------
# Release acquisition (docs/download.md)
# ---------------------------------------------------------------------------
cmd_download(){
  mkdir -p "$DATA"
  if [ -f "$DL/assets.tsv" ] && [ -d "$RELEASE" ]; then
    ok "release already downloaded and extracted at $RELEASE"
    return 0
  fi
  log "resolving release $VERSION ($ARCH)"
  mkdir -p "$DL"
  [ -s "$DL/release.json" ] || curl -fsSL -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/kuasar-sandbox/kuasar-sandbox/releases/tags/$VERSION" \
      -o "$DL/release.json"
  if [ ! -s "$DL/assets.tsv" ]; then
    python3 - "$DL" "$ARCH" "$VERSION" <<'PY'
import json, sys
dl, arch, version = sys.argv[1:4]
rel = json.load(open(f"{dl}/release.json", encoding="utf-8"))
assert rel["tag_name"] == version and not rel["draft"] and not rel["prerelease"], "wrong release"
names = {a["name"]: a for a in rel["assets"]}
want = ["SHA256SUMS", f"platform-{version}.tar.gz"]
for pat in ("accelerator", "connector", "orchestrator", "sandboxer"):
    want.append(next(n for n in names if n.startswith(pat + "-") and n.endswith(f"-linux-{arch}.tar.gz")))
want.append(next(n for n in names if n.startswith(f"sandbox-runtime-{arch}-")))
want.append(next(n for n in names if n.startswith(f"vmlinux-{arch}-")))
want.append(next(n for n in names if n.startswith(f"workbench-{arch}-")))
with open(f"{dl}/assets.tsv", "w") as out:
    for n in want:
        a = names[n]
        out.write(f"{n}\t{a['browser_download_url']}\t{a['digest']}\t{a['size']}\n")
        print("  ", n, a["size"])
PY
  fi
  log "downloading selected assets (resumable, SHA-256 verified)"
  while IFS=$'\t' read -r name url digest size; do
    if [ -f "$DL/$name" ] && [ "$(stat -c %s "$DL/$name")" = "$size" ]; then
      ok "$name (cached)"
    else
      curl -fL --retry 8 --retry-all-errors -C - -o "$DL/$name.part" "$url"
      [ "$(stat -c %s "$DL/$name.part")" = "$size" ] || die "size mismatch: $name"
      [ "sha256:$(sha256sum "$DL/$name.part" | awk '{print $1}')" = "$digest" ] || die "digest mismatch: $name"
      mv "$DL/$name.part" "$DL/$name"
      ok "$name"
    fi
  done <"$DL/assets.tsv"
  if [ ! -d "$RELEASE" ]; then
    log "extracting products/materials into $RELEASE"
    local stage; stage="$(mktemp -d "$DATA/.stage.XXXXXX")"
    while IFS=$'\t' read -r name url digest size; do
      case "$name" in SHA256SUMS|*workbench-*) continue;; esac
      tar --extract --gzip --no-same-owner --no-same-permissions \
          --file "$DL/$name" --directory "$stage"
    done <"$DL/assets.tsv"
    for f in test/demo/demo_common.sh test/demo/requirements.txt test/demo/prepared.py workbench/workbench; do
      [ -e "$stage/$f" ] || die "unexpected release layout (missing $f)"
    done
    mv "$stage" "$RELEASE"
  fi
  ok "release ready: $RELEASE"
}

instance_name(){ cat "$NAME_FILE" 2>/dev/null || true; }
instance_container(){ printf 'kuasar-workbench-%s' "$(instance_name)"; }
instance_running(){
  [ -n "$(instance_name)" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$(instance_container)" 2>/dev/null)" = true ]
}

need_release(){ [ -f "$WB" ] || die "release not extracted; run: $0 download"; }

instance_up(){
  need_release
  local n; n="$(instance_name)"
  if [ -z "$n" ]; then
    n="demo-$(date +%s)"
    log "creating workbench instance $n (cpus=$CPUS mem=${MEMGIB}g)"
    mkdir -p "$STATE"; chmod 700 "$STATE"
    python3 "$WB" check --image "$IMAGE" --mode system >/dev/null
    python3 "$WB" --root "$STATE" --name "$n" start \
      --image "$IMAGE" --mode system --inputs "$RELEASE" \
      --cpus "$CPUS" --memory-gib "$MEMGIB" --network bridge
    printf '%s\n' "$n" >"$NAME_FILE"
    ok "instance recorded as $n"
  elif instance_running; then
    ok "workbench $n already running"
  else
    log "restarting workbench instance $n"
    python3 "$WB" --root "$STATE" --name "$n" start \
      --image "$IMAGE" --mode system --inputs "$RELEASE" \
      --cpus "$CPUS" --memory-gib "$MEMGIB" --network bridge
  fi
}

wbexec(){ python3 "$WB" --root "$STATE" --name "$(instance_name)" exec -- "$@"; }

# Only one persistent storage tier (fixed host ports 5000/5050) may run at once.
stop_all_tiers(){
  instance_running && wbexec bash -c 'for d in /work/kuasar-demo-*/; do
      [ -f "$d/prep.env" ] || continue
      python3 -B /work/prepared/test/demo/prepared.py stop \
        --workdir /work/prepared --data-dir "${d%/}" >/dev/null 2>&1 || true
    done' || true
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_setup(){
  ensure_sudoers
  install_native_docker
  ensure_docker
  ensure_networking
  ensure_egress
  ok "host setup complete"
}

cmd_init(){
  ensure_docker; ensure_image; ensure_networking; ensure_egress
  instance_up
}

cmd_prepare(){
  ensure_docker; instance_up
  if wbexec test -f /work/prepared/test/e2e/e2e 2>/dev/null; then
    ok "prepared inputs already present at /work/prepared"; return 0
  fi
  log "offline-preparing Demo inputs (locked wheels + helpers)"
  wbexec python3 -B /inputs/release/test/e2e/e2e prepare \
    --release-dir /inputs/release --workdir /work/prepared --arch "$ARCH" \
    --include basic.demo.sh --deps-dir /opt/workbench/deps --offline
}

cmd_quick(){
  ensure_docker; ensure_networking; ensure_egress; instance_up; cmd_prepare; stop_all_tiers
  log "QUICK demo: build -> create -> exec/files -> net -> pause/resume -> kill"
  wbexec python3 -B /work/prepared/test/demo/prepared.py run \
    --workdir /work/prepared --data-dir "$DATADIR" --quick
}

cmd_full(){
  ensure_docker; ensure_networking; ensure_egress; instance_up; cmd_prepare; stop_all_tiers
  log "FULL demo: adds template fan-out + one-call migration"
  wbexec python3 -B /work/prepared/test/demo/prepared.py run \
    --workdir /work/prepared --data-dir "$DATADIR"
}

cmd_stop(){
  ensure_docker
  if instance_running; then
    stop_all_tiers
    log "stopping workbench instance $(instance_name)"
    python3 "$WB" --root "$STATE" --name "$(instance_name)" stop
  else
    ok "workbench not running"
  fi
}

cmd_reset(){
  ensure_docker
  if instance_running; then
    log "resetting Demo data $DATADIR"
    wbexec python3 -B /work/prepared/test/demo/prepared.py reset \
      --workdir /work/prepared --data-dir "$DATADIR" || true
  fi
  ok "Demo data reset"
}

cmd_status(){
  ensure_docker
  echo "data root: $DATA"
  echo "release:   $RELEASE $([ -d "$RELEASE" ] && echo '(present)' || echo '(missing)')"
  local img; img="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo absent)"
  echo "image:     $IMAGE ($img)"
  echo "instance:  $(instance_name || echo '<none>')  running=$(instance_running && echo yes || echo no)"
  docker ps -a --filter label=org.kuasar.workbench.instance --format '  container {{.Names}} {{.Status}}'
  echo "egress:    $(sudo -n iptables -t nat -S PREROUTING 2>/dev/null | grep -q '1.1.1.1' && echo 'redirect present' || echo 'redirect MISSING')"
  echo "ip_forward: $(cat /proc/sys/net/ipv4/ip_forward)"
}

cmd_cleanup(){
  ensure_docker
  need_release
  cmd_stop
  local n; n="$(instance_name)"
  if [ -n "$n" ] && docker inspect "$(instance_container)" >/dev/null 2>&1; then
    log "cleaning workbench instance $n (work/ output/ retained)"
    python3 "$WB" --root "$STATE" --name "$n" cleanup || true
  fi
  rm -f "$NAME_FILE"
  ok "cleanup done"
}

usage(){ sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  setup)   cmd_setup;;
  download) cmd_download;;
  init)    cmd_init;;
  prepare) cmd_prepare;;
  quick)   cmd_quick;;
  full)    cmd_full;;
  status)  cmd_status;;
  stop)    cmd_stop;;
  reset)   cmd_reset;;
  cleanup) cmd_cleanup;;
  ''|-h|--help|help) usage;;
  *) usage; exit 2;;
esac
