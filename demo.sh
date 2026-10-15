#!/usr/bin/env bash
# =============================================================================
# Kuasar Sandbox — single-node Demo deployment.
#   Path A: aggregate release + workbench, no source build (setup/quick/full).
#   Path B: build the components from source, then run the Demo (src-*).
# Target environment: this WSL2 host (Ubuntu
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
# Path B (source build; for changing component code) — see DEPLOY.md "Path B":
#   ./demo.sh src-clone  # clone/refresh the 5 component repos at pinned tags
#   ./demo.sh src-build  # build all products from source (workbench build mode)
#   ./demo.sh src-demo [quick]  # run the Demo against source-built binaries
#   ./demo.sh src-full  # full source-build Demo (fan-out + migration)
#   ./demo.sh src-status # show component checkouts + source-built products
#   ./demo.sh src-clean  # remove leaf build outputs (keeps deps + caches)
#   ./demo.sh src-full-clean # remove dependency builds too (next build is cold)
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

# --- Path B (source build) configuration ------------------------------------
SRC_ROOT="${KUASAR_SRC_ROOT:-$(dirname "$REPO")}"   # parent of the 6 repos
BUILD_STATE="$DATA/kuasar-build-state"
BUILD_NAME="build"
BUILD_NAME_FILE="$DATA/.build-name"
GOPROXY_VALUE="${GOPROXY:-https://goproxy.cn,direct}"   # proxy.golang.org is blocked here
CARGO_MIRROR="${CARGO_MIRROR:-https://rsproxy.cn/index/}"  # static.crates.io is throttled here
SRC_DEMO_DATA="$DATA/kuasar-demo-source"
# Component pins for the aggregate release selected above (from releases/release.yaml).
# guest-runtime uses the runtime tag; the kernel (vmlinux) is a separate tag.
pins(){ case "${1:-$VERSION}" in
  release-v0.1.6) cat <<'EOF'
accelerator git v0.1.6
connector git v0.1.5
sandboxer git v0.1.6
orchestrator git v0.1.6
guest-runtime git runtime-v0.1.6
EOF
;; *) die "no component pins recorded for ${1:-$VERSION}; see releases/release.yaml" ;;
esac; }

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
# Path B — source build (change component code, rebuild, re-run)
# ---------------------------------------------------------------------------
build_instance_running(){
  [ "$(docker inspect -f '{{.State.Running}}' "kuasar-workbench-$BUILD_NAME" 2>/dev/null)" = true ]
}

src_build_instance_up(){
  need_release
  if build_instance_running; then ok "build instance already running"; return 0; fi
  if docker inspect "kuasar-workbench-$BUILD_NAME" >/dev/null 2>&1; then
    log "restarting build instance"
    python3 "$WB" --root "$BUILD_STATE" --name "$BUILD_NAME" start \
      --image "$IMAGE" --mode build --source "$SRC_ROOT" --cpus "${BUILD_CPUS:-4}" --memory-gib "${BUILD_MEMGIB:-6}"
    return 0
  fi
  log "creating build instance (source=$SRC_ROOT)"
  mkdir -p "$BUILD_STATE"; chmod 700 "$BUILD_STATE"
  python3 "$WB" --root "$BUILD_STATE" --name "$BUILD_NAME" start \
    --image "$IMAGE" --mode build --source "$SRC_ROOT" --cpus "${BUILD_CPUS:-4}" --memory-gib "${BUILD_MEMGIB:-6}"
  printf '%s\n' "$BUILD_NAME" >"$BUILD_NAME_FILE"
}

bexec(){ python3 "$WB" --root "$BUILD_STATE" --name "$BUILD_NAME" exec -- "$@"; }

# One-time per-instance: seed the build HOME with China-accessible mirrors and
# seed the expensive, code-independent guest kernel from the selected release
# so `make build` only (re)compiles what actually changed.
src_seed_build_env(){
  bexec bash -lc "go env -w GOPROXY=$GOPROXY_VALUE >/dev/null && mkdir -p /work/home/.cargo && cat > /work/home/.cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = \"rsproxy-sparse\"
[source.rsproxy-sparse]
registry = \"sparse+$CARGO_MIRROR\"
[net]
git-fetch-with-cli = true
EOF"
  local vmlinux="$RELEASE/bin/vmlinux"
  if [ -f "$vmlinux" ]; then
    bexec bash -lc "mkdir -p /src/guest-runtime/native-deps/bin/$ARCH && \
      if [ ! -s /src/guest-runtime/native-deps/bin/$ARCH/vmlinux ]; then \
        cp -f /inputs/release/bin/vmlinux /src/guest-runtime/native-deps/bin/$ARCH/vmlinux; \
      fi" 2>/dev/null || true
  fi
}

cmd_src_clone(){
  mkdir -p "$SRC_ROOT"
  local name kind tag dir
  while read -r name kind tag; do
    dir="$SRC_ROOT/$name"
    if [ -d "$dir/.git" ]; then
      ok "$name already cloned ($(git -C "$dir" describe --tags --always 2>/dev/null || echo '?'))"
      continue
    fi
    log "cloning $name @ $tag -> $dir"
    git clone --branch "$tag" --depth 1 "https://github.com/kuasar-sandbox/$name.git" "$dir"
  done < <(pins)
  ok "component checkouts present under $SRC_ROOT"
}

src_products(){ ls "$REPO/bin/$ARCH" 2>/dev/null; }

cmd_src_build(){
  src_build_instance_up
  src_seed_build_env
  # e2e-tools: reuse zot/versitygw already shipped with the release instead of
  # re-downloading from the (throttled) GitHub release CDN.
  local tools="$REPO/build/e2e-tools/$ARCH"
  mkdir -p "$tools"
  for t in zot versitygw; do
    if [ ! -s "$tools/$t" ] && [ -s "$RELEASE/test/e2e/helpers/$ARCH/$t" ]; then
      cp -f "$RELEASE/test/e2e/helpers/$ARCH/$t" "$tools/$t"
      ok "seeded build/e2e-tools/$ARCH/$t from release helpers"
    fi
  done
  log "building all products from source (make build)"
  bexec bash -lc 'set -o pipefail; cd /src/kuasar-sandbox && make build 2>&1 | tail -40; echo "MAKE_EXIT=${PIPESTATUS[0]}"'
  log "source products in $REPO/bin/$ARCH:"
  src_products | sed 's/^/    /'
}

src_host_prep(){
  ensure_networking; ensure_egress
  local venv="$REPO/.demo-venv"
  if [ ! -x "$venv/bin/python3" ]; then
    log "creating Demo virtualenv $venv (pinned e2b)"
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q --disable-pip-version-check \
      --requirement "$REPO/test/demo/requirements.txt"
  fi
  for t in openssl ip curl sqlite3 iptables flock setsid timeout mkfs.ext4; do
    command -v "$t" >/dev/null 2>&1 || die "missing host tool for the Demo: $t"
  done
}

stop_src_tier(){
  [ -f "$SRC_DEMO_DATA/prep.env" ] || return 0
  sudo -n env DEMO_DATA_DIR="$SRC_DEMO_DATA" DOCKER_HOST="$DOCKER_HOST" PATH="$PATH" \
    bash "$REPO/test/demo/demo_prep.sh" stop >/dev/null 2>&1 || true
  # A rebuild replaces the binaries under any still-running tier, after which
  # the ownership check (exe path + starttime) can no longer verify them and
  # `stop` refuses to act. If ports 5000/5050 are still held by our own
  # (now-"(deleted)") processes, clear them so the run can proceed safely.
  local port pid exe
  for port in 5000 5050; do
    pid="$(sudo -n ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
    [ -n "$pid" ] || continue
    exe="$(sudo -n readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    case "$exe" in
      *kuasar-sandbox*|*kuasar-deploy-data*)
        warn "stale Demo tier still holds port $port (pid $pid, $exe); terminating"
        sudo -n kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        sudo -n kill -0 "$pid" 2>/dev/null && sudo -n kill -KILL "$pid" 2>/dev/null || true ;;
    esac
  done
  sudo -n rm -f "$SRC_DEMO_DATA"/pids/*.pid 2>/dev/null || true
}

cmd_src_demo(){
  [ -x "$REPO/bin/$ARCH/node-ctl" ] || die "no source build in $REPO/bin/$ARCH; run: $0 src-build"
  src_host_prep
  # The persistent storage tier owns fixed host ports 5000/5050; stop any prior
  # source-build tier (and note Path A uses a different dir, so avoid running both).
  stop_src_tier
  if [ -n "$(instance_name)" ] && instance_running; then
    warn "Path A workbench instance is running; its storage tier may also hold 5000/5050"
  fi
  local quick="${1:-}"
  log "preparing persistent Demo storage tier (source-built binaries)"
  sudo -n env DEMO_DATA_DIR="$SRC_DEMO_DATA" BIN="$REPO/bin/$ARCH" \
    ZOT_BIN="$REPO/build/e2e-tools/$ARCH/zot" \
    VGW_BIN="$REPO/build/e2e-tools/$ARCH/versitygw" \
    DOCKER_HOST="$DOCKER_HOST" PATH="$PATH" \
    bash "$REPO/test/demo/demo_prep.sh" 2>&1 | tail -15
  log "running the Demo against source-built binaries${quick:+ (quick)}"
  sudo -n env DEMO_DATA_DIR="$SRC_DEMO_DATA" BIN="$REPO/bin/$ARCH" \
    PYTHON_BIN="$REPO/.demo-venv/bin/python3" ${quick:+DEMO_QUICKSTART=1} \
    DOCKER_HOST="$DOCKER_HOST" PATH="$PATH" \
    bash "$REPO/test/demo/demo_e2b.sh"
}

cmd_src_status(){
  echo "source root: $SRC_ROOT"
  local name kind tag dir commit
  while read -r name kind tag; do
    dir="$SRC_ROOT/$name"
    if [ -d "$dir/.git" ]; then
      commit="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
      printf '  %-16s %s (%s)\n' "$name" "$tag" "$commit"
    else
      printf '  %-16s MISSING\n' "$name"
    fi
  done < <(pins)
  echo "products:    $REPO/bin/$ARCH"
  if [ -d "$REPO/bin/$ARCH" ]; then
    src_products | sed 's/^/             /'
  else
    echo "             (not built; run: $0 src-build)"
  fi
  echo "build inst:  $BUILD_NAME running=$(build_instance_running && echo yes || echo no)"
}

cmd_src_clean(){
  # NOTE: the repos' own `make clean` also deletes accelerator/build (librocksdb)
  # and sandboxer native-deps build (cloud-hypervisor) — forcing a multi-minute
  # full rebuild. This target therefore removes only the assembled/leaf outputs
  # by default, keeping the expensive dependency builds cached. For a truly
  # pristine rebuild, remove the seeds and use: ./demo.sh src-full-clean.
  if build_instance_running; then
    log "removing assembled and leaf build outputs (keeping heavy deps)"
    bexec bash -lc 'set -e
      rm -rf /src/kuasar-sandbox/bin/x86_64 /src/kuasar-sandbox/bin/.* 2>/dev/null || true
      find /src/kuasar-sandbox/bin -maxdepth 1 -type l -delete 2>/dev/null || true
      for d in accelerator sandboxer orchestrator connector; do
        rm -rf "/src/$d/bin/x86_64"; find "/src/$d/bin" -maxdepth 1 -type l -delete 2>/dev/null || true
      done
      rm -f /src/guest-runtime/bin/x86_64/flatten-ctl /src/guest-runtime/bin/x86_64/sandbox-runtime.bundle
      rm -f /src/guest-runtime/native-deps/bin/x86_64/envd /src/guest-runtime/native-deps/bin/x86_64/mkfs.erofs
      # Keep the seeded vmlinux (kernel) and staged zot/versitygw helpers.'
  fi
  ok "leaf build outputs cleaned (kernel seed, deps and Go/Cargo caches kept)"
}

cmd_src_full_clean(){
  if build_instance_running; then
    log "full clean: removing dependency builds too (next build is cold)"
    bexec bash -lc 'cd /src/kuasar-sandbox && make clean >/dev/null 2>&1 || true
      for d in accelerator sandboxer orchestrator connector guest-runtime; do
        make -C "/src/$d" clean >/dev/null 2>&1 || true
      done'
    # Re-seed the code-independent kernel and helper tools.
    bexec bash -lc "mkdir -p /src/guest-runtime/native-deps/bin/$ARCH" 2>/dev/null || true
    bexec bash -lc "cp -f /inputs/release/bin/vmlinux /src/guest-runtime/native-deps/bin/$ARCH/vmlinux 2>/dev/null || true" 2>/dev/null || true
  fi
  ok "full clean done (kernel/tools re-seeded if available)"
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

usage(){ awk 'NR==1{next} /^# ===/{b++; if(b>1) exit; next} b==1 && /^#/{sub(/^# ?/,""); print}' "$0"; }

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
  src-clone)  cmd_src_clone;;
  src-build)  cmd_src_build;;
  src-demo)   cmd_src_demo "${2:-}";;
  src-full)   cmd_src_demo "";;
  src-status) cmd_src_status;;
  src-clean)  cmd_src_clean;;
  src-full-clean) cmd_src_full_clean;;
  ''|-h|--help|help) usage;;
  *) usage; exit 2;;
esac
