# 部署指南 — Kuasar Sandbox 单机 Demo（本环境实测可用）

本指南针对**当前这台机器**（WSL2 + Ubuntu 24.04 + 原生 `/dev/kvm` + 本机
Clash 代理 + 已装 Docker Desktop）编写，目标是**跑通 E2B Demo**，不涉及生产
集群支撑。提供两条路径，按需选择：

- **Path A — 聚合 Release + Workbench（不编译源码）**：官方推荐的首用/验证路径。
  适合只想跑通 Demo、不改代码。
- **Path B — 源码编译（改代码用）**：clone 五个组件仓库，`make build` 从源码
  产出全部产品，再对源码产物跑 Demo。适合**需要修改组件代码**的场景。

两条路径共用同一套前置（第 1 节）与同一批环境适配（第 4 节）。

- 一键脚本：`./demo.sh`（本仓库根目录）——Path A 用 `setup/download/quick/full`，
  Path B 用 `src-clone/src-build/src-demo/src-status/src-clean`
- 指南：本文件 `DEPLOY.md`
- 官方原文档：`docs/quickstart.md`、`docs/download.md`、`workbench/README.md`、
  `test/demo/DEMO.md`（Path A）；`Makefile`、`workbench/README.md`（build 模式）、
  `test/demo/DEMO.md` §4（Path B）

---

## 0. 环境约定

| 项 | 值 |
|---|---|
| 仓库 | `/home/cyx/Codes/kuasar-sandbox` |
| 部署数据根 | `/home/cyx/kuasar-deploy-data`（可用 `KUASAR_DEPLOY_DATA` 覆盖） |
| 版本 | `release-v0.1.6`（可用 `RELEASE_VERSION` 覆盖） |
| workbench 镜像 | `ghcr.io/kuasar-sandbox/workbench:v0.1.6` |
| 原生 Docker socket | `unix:///run/docker-native.sock`（systemd 单元 `docker-native.service`） |
| workbench 数据目录（容器内） | `/work/kuasar-demo-run` |
| 资源预算 | 6 CPU / 6 GiB（可用 `WB_CPUS`、`WB_MEMGIB` 覆盖） |
| 源码根（Path B） | `/home/cyx/Codes`（六个仓库的父目录，`KUASAR_SRC_ROOT` 可覆盖） |
| 源码产物（Path B） | `kuasar-sandbox/bin/x86_64/` |
| 源码 Demo 数据（Path B） | `/home/cyx/kuasar-deploy-data/kuasar-demo-source` |

**所有重型数据都在 `/home/cyx/kuasar-deploy-data`（约 3.7 GB），仓库里只放脚本和文档。**

---

## 1. 前置条件（本机已全部满足）

- 原生 x86_64 Linux（WSL2），systemd 为 PID 1，cgroup v2，`/dev/kvm` 可读写。
- 内核具备：BPF/JIT、TC clsact、userfaultfd、TUN/TAP、veth/bridge、vsock、overlayfs。
- **本地 rootful 原生 Docker Engine**（关键，见 §5.1）。
- **passwordless sudo**（关键，见 §5.2）。
- 本机 Clash 代理可用（`~/.bashrc` 已按默认网关动态设置）。

自检命令（成功即满足）：
```bash
python3 - <<'PY'
import fcntl, os
with open('/dev/kvm','rb+',buffering=0) as k:
    assert fcntl.ioctl(k,0xAE00)==12; vm=fcntl.ioctl(k,0xAE01,0); os.close(vm)
print("KVM OK")
PY
sudo -n true && echo "sudo OK"
DOCKER_HOST=unix:///run/docker-native.sock docker info --format '{{.OperatingSystem}}'
```

---

## 2. 一键流程（首次部署）

在**本仓库根目录**执行：

```bash
cd /home/cyx/Codes/kuasar-sandbox

./demo.sh setup      # 主机准备：passwordless sudo、原生 Docker、ip_forward、出网修复
./demo.sh download   # 下载并 SHA-256 校验聚合 Release、解包、导入 workbench 镜像
./demo.sh init       # 创建并启动 workbench 私有系统环境
./demo.sh prepare    # 在 workbench 内离线准备 Demo 输入（锁定 wheel + helper）
./demo.sh quick      # 跑短 Demo  ← 最短验证
# 或：
./demo.sh full       # 跑完整 Demo（额外含模板 fan-out 与一次性 migration）
```

`download` 需要拉取约 1.3 GB 的 workbench 镜像归档 + ~400 MB 产品包，请留出时间与磁盘。
`setup` 与 `init` 都是**幂等**的，可重复执行。

> 以上是 **Path A**。若你要**改代码**，改走 **Path B（第 4 节）**：`src-clone`→`src-build`→`src-demo`。

---

## 3. 日常使用

```bash
# Path A（预编译产物）
./demo.sh status     # 查看数据根/版本/镜像/实例/容器/出网规则/ip_forward
./demo.sh quick      # 重跑短 Demo（自动重启实例、停掉上一次的持久存储层）
./demo.sh full       # 重跑完整 Demo
./demo.sh stop       # 停 Demo 存储层 + 停 workbench 实例（保留数据）
./demo.sh reset      # 删除 workbench 内 Demo 数据
./demo.sh cleanup    # 停 + 删除 workbench 容器（保留 work/output 目录）

# Path B（源码产物）—— 详见第 4 节
./demo.sh src-clone    # clone/刷新五个组件仓库
./demo.sh src-build    # 从源码重建全部产品（增量）
./demo.sh src-demo quick   # 对源码产物跑短 Demo
./demo.sh src-full         # 对源码产物跑完整 Demo
./demo.sh src-status   # 组件检出 + 源码产物
./demo.sh src-clean    # 清理源码构建产物
```

重跑逻辑：`demo.sh` 会复用已有实例与已 prepare 的输入；由于 Demo 的持久存储层
（Registry/VersityGW）**独占宿主固定端口 5000/5050**，同一时刻只能有一个数据目录的
存储层在跑，脚本在每次 `quick/full` 前会先 `stop_all_tiers`。

进入 workbench 交互 shell（需要 TTY）：
```bash
python3 /home/cyx/kuasar-deploy-data/release-v0.1.6/workbench/workbench \
  --root /home/cyx/kuasar-deploy-data/kuasar-workbench-state \
  --name "$(cat /home/cyx/kuasar-deploy-data/.wb-name)" exec
```

---

## 4. Path B — 源码编译（改代码用）

当你要**修改组件代码**时走这条。它 clone 五个组件仓库、从源码编译出全部产品，
再对源码产物跑 Demo。与 Path A 的关键区别：Path A 消费官方预编译产物，
Path B 产出你自己的产物（`bin/<arch>/`）。

### 4.1 一次性的准备

```bash
cd /home/cyx/Codes/kuasar-sandbox
./demo.sh src-clone    # 在 ../ 下 clone 五个组件仓库（按 release 锁定 tag）
./demo.sh src-build    # 从源码构建全部产品（workbench build 模式）
./demo.sh src-status   # 查看组件检出与产物
```

`src-clone` 会 clone 到 `../`（即 `/home/cyx/Codes/`），与 `kuasar-sandbox` 同级
——这正是 `Makefile` 里 `ORG := $(CURDIR)/..` 的约定。锁定 tag 来自本仓库的
`releases/release.yaml`：

| 仓库 | tag（release-v0.1.6） |
|---|---|
| accelerator | `v0.1.6` |
| connector | `v0.1.5` |
| sandboxer | `v0.1.6` |
| orchestrator | `v0.1.6` |
| guest-runtime | `runtime-v0.1.6`（内核 `vmlinux` 是独立 tag `vmlinux-v0.1.4`） |

注意 **connector 是 `v0.1.5`**，不是 v0.1.6——聚合版本里各组件版本不等，务必按
`releases/release.yaml` 来，不要想当然。

### 4.2 编译在哪发生：workbench build 模式

`src-build` 用一个 **workbench `--mode build`** 实例：把 `/home/cyx/Codes`（六个
仓库的父目录）只读挂载到 `/src`，容器内自带 Go 1.26 / Rust/Cargo / clang / mkfs.erofs，
以你的 UID 运行、去掉所有权限、只读根文件系统。构建产物写回 `bin/<arch>/` 和各仓库的
`bin/`（因为 `/src` 是可写的 bind mount）。这避免在主机上安装整套工具链。

`make build` 的顺序由 `Makefile` 固定：

```
guest-runtime/native-deps → accelerator → sandboxer → guest-runtime
                          → connector → orchestrator → collect
```

`collect` 把各仓库产物汇总到 `kuasar-sandbox/bin/<arch>/`，并生成 native 架构软链。

### 4.3 本机两处构建适配（已写进 `demo.sh src-build`）

1. **Go 模块代理**：本机（经 Clash）**直连 `proxy.golang.org` 会超时**，而容器又够不着
   Clash 代理。`src-build` 会自动给 build 实例写入
   `go env -w GOPROXY=https://goproxy.cn,direct`（国内可直连，已验证）。
2. **Cargo 源**：`static.crates.io` 在本容器被限速（实测 ~58 KB/s，301 个 crate 会卡死）。
   `src-build` 自动写入 `~/.cargo/config.toml`，把 crates-io 换成
   `sparse+https://rsproxy.cn/index/`（国内镜像，已验证）。cloud-hypervisor 还依赖
   GitHub 上的 git 依赖（`micro-http`、`rust-vmm-ci`），这些直连 GitHub 即可。

另外 `src-build` 会：把 release 里已带的 `zot`/`versitygw` **播种**到
`build/e2e-tools/<arch>/`（避免从被限速的 GitHub Release CDN 重新下载）；并把
**上游内核 `vmlinux` 从 release 播种**到 `guest-runtime/native-deps/bin/<arch>/`
（内核与你要改的 Go/Rust 代码无关，且冷编译需数分钟）。

> 关于内核：如果你想连内核也自己编，删掉
> `guest-runtime/native-deps/bin/<arch>/vmlinux` 后重跑 `src-build` 即可
> （会触发 `native-deps` 的完整 `fetch+patches-apply+build`）。

### 4.4 跑 Demo（对源码产物）

```bash
./demo.sh src-demo quick   # 短 Demo，对源码产物
./demo.sh src-full         # 完整 Demo（fan-out + migration）
```

这两条走的是官方的 **native source 路径**（`test/demo/DEMO.md` §4）：直接在宿主机
（非 workbench 容器）用 `bin/<arch>/` 的源码产物跑 `demo_prep.sh` + `demo_e2b.sh`。
脚本会自动：确保 `ip_forward=1` 与出网重定向、创建 `.demo-venv`（安装锁定版 `e2b`）、
检查宿主机 Demo 工具（openssl/ip/curl/sqlite3/iptables/flock/setsid/timeout/mkfs.ext4）。

> Path A 与 Path B 的 Demo 数据目录不同（`/work/kuasar-demo-run` vs
> `/home/cyx/kuasar-deploy-data/kuasar-demo-source`），且持久存储层独占 5000/5050，
> 所以两者不要同时跑。

### 4.5 改代码 → 重建 → 再跑（这就是你要的循环）

```bash
cd /home/cyx/Codes/orchestrator       # 或 accelerator / sandboxer / connector / guest-runtime
$EDITOR cmd/node-ctl/main.go          # 改代码
cd /home/cyx/Codes/kuasar-sandbox
./demo.sh src-build                   # 增量重建（只重编变更的仓库/包）
./demo.sh src-demo quick              # 用新产物再跑一遍
```

实测：仅改 orchestrator 的一个字符串，增量 `src-build` 约 **11 秒**（Go 侧增量很快）；
冷构建（首次，含 cloud-hypervisor + librocksdb）在本机约 **30–40 分钟**，之后大幅缩短。

各仓库就是普通 git 检出（默认在锁定 tag 的 detached HEAD）。要改代码建议建分支：

```bash
cd /home/cyx/Codes/orchestrator && git switch -c my/change
```

### 4.6 清理

```bash
./demo.sh src-clean        # 只删叶子产物（保留依赖构建、Go/Cargo 缓存、内核种子）
./demo.sh src-full-clean   # 连依赖构建一起删，下次是冷构建
```

注意：各仓库自带的 `make clean` 会一并删掉 `accelerator/build`（librocksdb）与
`sandboxer/native-deps` 的 cloud-hypervisor 构建，导致下次数分钟冷编。因此默认的
`src-clean` **不调用**各仓库 `make clean`，只删装配产物；需要彻底重建时才用
`src-full-clean`。

要整体移除：用 `workbench` 的 `cleanup` 删除 build 实例（build 模式的 `cleanup`
会连同 `work/`、`build/`、`output/` 一起清掉）。

---

## 5. 本环境的四处适配（为什么不能照官方文档直接跑）

### 5.1 Docker Desktop 不被 workbench 接受 → 用原生引擎

`docs/quickstart.md` 说"不支持 Docker Desktop、远端 Docker 端点"，而本机 WSL
集成里 Docker Desktop 正占着默认 socket。`workbench/workbench` 的 `host_check`
是硬判据：

```python
info['KernelVersion'] == platform.release() and 'Docker Desktop' not in info['OperatingSystem']
```

因此 `demo.sh setup` 会：安装 Ubuntu 原生 `docker.io` + `containerd`，禁用发行版
默认 `docker.service/docker.socket`，并建立独立服务 **`docker-native.service`**，
监听 `unix:///run/docker-native.sock`（已 `enable`，开机自启）。`demo.sh` 全程用
`DOCKER_HOST` 指向该 socket。

Docker Desktop 本身仍可照常使用；两套引擎互不干扰，只是 workbench 只认原生这套。

### 5.2 需要 passwordless sudo

Demo 的 prepare/run 大量使用 `sudo -n`，且 `prepared.py` 要求 `geteuid()==0`。
`demo.sh setup` 会读取仓库内的 `env`（内容形如 `export SUDO_PASSWORD=...`），
写入 `/etc/sudoers.d/90-cyx-nopasswd`（`cyx ALL=(ALL) NOPASSWD: ALL`）。
若已具备免密 sudo，则跳过。

### 5.3 daemon 自身必须走 Clash 代理

本机出网经 Clash（Windows 宿主 = WSL 默认网关），原生 dockerd 直连会
`connection reset by peer`。`docker-native.service` 通过启动脚本
`/usr/local/libexec/docker-native-launch.sh` **在启动时动态解析默认网关**并注入
`http_proxy/https_proxy`（端口 7897；可用 `CLASH_PROXY_PORT` 覆盖），
避免 WSL 重启后网关变化导致失效。

### 5.4 `1.1.1.1` 被本机网络阻断 → host DNAT 修复

Demo 的出网断言**硬编码** `http://1.1.1.1:80/`（`test/demo/demo_e2b.sh`），而本机
（经 Clash）**无法直连 `1.1.1.1`**：`ping` 100% 丢包、TCP 超时；其它公网 IP
（`1.0.0.1`、`8.8.8.8`、`example.com`）均正常。这不是 NAT bug，是环境限制。

`demo.sh setup`（及每次 `quick/full`）确保存在一条 host 规则：

```bash
iptables -t nat -A PREROUTING -d 1.1.1.1 -p tcp --dport 80 \
    -j DNAT --to-destination 1.0.0.1:80
```

它只重定向这一条被测流到可达的 Cloudflare 边缘，**仍经真实 NAT 访问真实公网**，
因此没有削弱断言语义，也没有使用官方禁止的 `DEMO_NETDIAG` 作弊开关。

> 注意：`iptables` 规则**不随重启保留**；重启后直接跑 `./demo.sh quick|full`
> 会自动补上，无需手工干预。

---

## 6. 验证：预期结果

`./demo.sh quick` 成功时，末尾应出现：

```
══════ quick start complete — built, created, ran, paused/resumed, and killed via the e2b Python SDK ══════
```

`./demo.sh full` 成功时，末尾应出现：

```
══════ demo complete — built (full 3-phase pipeline → snapshot), created, ran, served the built site,
paused/resumed, forked-to-template, migrated, killed — all via the e2b Python SDK ══════
```

Path B 的 `./demo.sh src-demo quick` / `src-full` 输出与上面完全一致——区别只在于
它们用的是**你源码编译出的** `bin/<arch>/`，而非官方预编译产物。

逐阶段断言（`test/demo/DEMO.md` 的表）：

| # | 阶段 | 期望 |
|---|---|---|
| 1 | Node stack | Conductor/Proxy 就绪，eBPF vSwitch + NAT 起来 |
| 2 | Tenant | ManifestKey + 派生 API key 下发 |
| 3 | Build | 3 阶段流水线 → `kind=snp` 快照模板 `e2b-snp-*` |
| 4 | Create | 真实 Cloud Hypervisor MicroVM 通过 Proxy 可用 |
| 5 | Data | `commands.run` / `files` 返回断言内容 |
| 6 | Network | 端口转发可达 built 页面；**容器外访客 NAT 出网 HTTP 响应** |
| 7 | State | pause → connect 后数据存活 |
| 8 | Fan-out（full） | `export-sandbox --to-template` 后新建子沙箱继承状态 |
| 9 | Migration（full） | `connect(headers=migration-token)` 一步 import+resume |
| 10 | Destroy | `kill` 后资源回收 |

留存的非敏感日志：容器内 `/work/kuasar-demo-run/results/<run-id>/`；
宿主侧映射到 `/home/cyx/kuasar-deploy-data/kuasar-workbench-state/<name>/work/kuasar-demo-run/results/`。

---

## 7. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `refusing Docker Desktop` | `DOCKER_HOST` 指到了 Desktop | `export DOCKER_HOST=unix:///run/docker-native.sock`（`demo.sh` 已默认） |
| dockerd 拉镜像 `connection reset` | daemon 没走代理 | 检查 `docker-native-launch.sh` 解析出的网关是否可达；`CLASH_PROXY_PORT` 是否正确 |
| `1.1.1.1` 出网超时、`egress HTTP ...` 失败 | 出网 DNAT 规则缺失 | `./demo.sh setup`（或直接 `quick/full` 会自动补） |
| `127.0.0.1:5000 is already in use by a process not owned by this Demo` | 另一个数据目录的存储层仍在跑 | `./demo.sh stop`；脚本已在运行前自动 `stop_all_tiers` |
| `instance is already running` / 起不来 | 残留实例 | `./demo.sh status` 后 `./demo.sh stop`，必要时 `cleanup` 再 `init` |
| prepare 报缺输入/校验失败 | 输入不完整或损坏 | 用新的数据根重跑 `./demo.sh download`（校验失败不会静默替换） |
| 内存不足导致容器被 OOM | 本机仅 ~7.4 GiB | 降低 `WB_MEMGIB`（如 `WB_MEMGIB=5 ./demo.sh quick`）或关闭其它大进程 |
| `src-build` Go 拉模块超时 | 本机直连 `proxy.golang.org` 被墙 | 脚本已设 `GOPROXY=https://goproxy.cn,direct`；可用 `GOPROXY=` 覆盖 |
| `src-build` 卡在 cargo `Updating crates.io index` / 下载很慢 | `static.crates.io` 被限速 | 脚本已换 `rsproxy.cn` 镜像；确认 build 实例 HOME 下 `~/.cargo/config.toml` 存在 |
| `src-demo` 报 `Cannot connect to the Docker daemon` | `sudo` 丢了 `DOCKER_HOST` | 脚本通过 `sudo -n env ... DOCKER_HOST=...` 传递；手工跑时要显式带上 |
| `src-build` 报缺 `mkfs.erofs`/内核 | 未播种或未构建 | 先跑 `src-clone`；`src-build` 会从 release 播种 `vmlinux`+`zot`/`versitygw` |
| Path A 与 Path B Demo 互相冲突（5000/5050 占用） | 两条路径的持久存储层都占固定端口 | 先 `./demo.sh stop`（Path A）再跑 Path B，或反之；不要并行 |

查看某次运行的启动日志：`/home/cyx/kuasar-deploy-data/kuasar-workbench-state/<name>/output/`。

---

## 8. 清理与回滚

```bash
cd /home/cyx/Codes/kuasar-sandbox
./demo.sh cleanup                                   # 停并删 workbench 容器（保留 work/output）

# 可选：彻底移除
docker image rm ghcr.io/kuasar-sandbox/workbench:v0.1.6      # 约 3.5 GB
sudo rm -rf /home/cyx/kuasar-deploy-data                     # 下载缓存 + 解包 + 实例状态
sudo iptables -t nat -D PREROUTING -d 1.1.1.1 -p tcp --dport 80 -j DNAT --to-destination 1.0.0.1:80
sudo systemctl disable --now docker-native.service           # 若不再需要原生引擎
```

---

## 9. 与官方文档的差异一览

| 官方文档 | 本指南补充 |
|---|---|
| `quickstart.md`/`workbench/README.md`：不支持 Docker Desktop（只给结论） | §4.1 从 Desktop 迁移到自建原生引擎的完整步骤（独立 socket 的 systemd 单元） |
| `download.md`/`quickstart.md`：假设主机可直连 GitHub/Docker Hub | §4.3 daemon 走 Clash 代理，且网关地址动态解析 |
| `demo_e2b.sh` 硬编码 `1.1.1.1`；`quickstart.md` 禁止用 `DEMO_NETDIAG` 绕过失败 | §4.4 host DNAT 修复，保持真实出网语义 |
| `DEMO.md`：可重复运行，未提持久层独占固定端口 | §3 明确 5000/5050 独占，`demo.sh` 自动 `stop_all_tiers` |
| 仅在 `perf.md`/`test/QUICKSTART.md` 顺带提到 noninteractive sudo | §4.2 显式作为前置并自动配置 |
| 容量为"示例值"（4C/12GiB） | 本机实测 6C/6GiB 可跑通 quick/full（可用环境变量调整） |
| `Makefile` 假设六个仓库同级，但未说明如何在隔离环境取依赖/编译 | §4.2–§4.3：workbench build 模式 + Go(`goproxy.cn`)/Cargo(`rsproxy.cn`) 镜像 + 播种内核/zot/versitygw |
| `test/demo/DEMO.md` §4 native source 路径未给出本环境的 venv/工具链细节 | §4.4：`demo.sh src-demo` 自动建 venv、检查工具、补 `ip_forward`/出网 |

---

## 10. 参考

- `docs/quickstart.md`、`docs/download.md`、`workbench/README.md`、`test/demo/DEMO.md`
- 生产部署（本指南不涉及）：`docs/deployment.md`
- 完整发布验证（更重）：`test/QUICKSTART.md`
