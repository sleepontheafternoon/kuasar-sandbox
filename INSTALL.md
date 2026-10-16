# Kuasar Sandbox 安装指南（release-v0.1.6）

> 面向本机环境（WSL2 + Ubuntu 24.04）从零安装并验证 **release-v0.1.6** 的完整步骤。
> 内容基于一次真实的端到端安装记录整理，所有命令均已实测。文中给出的版本号、
> 校验值、端口、路径、耗时与坑位都是这台机器上的**实际观测**。

安装范围两种，按需选择：

| | 用途 | 是否需要编译 | 对应命令 |
|---|---|---|---|
| **方式 A** | 只跑 Demo / 验证环境 | 否（用官方预编译产物） | `setup → download → quick/full` |
| **方式 B** | 需要修改组件代码 | 是（源码构建） | `src-clone → src-build → src-demo` |

两者共用同一套宿主准备（第 1–3 节）。一键脚本：`./demo.sh`。更详细的原理与排障见 `DEPLOY.md`。

---

## 0. 版本与产物清单（release-v0.1.6）

本指南锁定以下**确切版本**，不要混用其它版本或分支：

| 组件 | 版本 / tag |
|---|---|
| 聚合版本 | `release-v0.1.6`（Stable） |
| orchestrator | `v0.1.6` |
| sandboxer | `v0.1.6` |
| accelerator | `v0.1.6` |
| connector | **`v0.1.5`**（注意不是 v0.1.6） |
| guest-runtime（runtime） | `runtime-v0.1.6` |
| guest-runtime（内核 vmlinux） | `vmlinux-v0.1.4` |
| workbench 镜像 | `ghcr.io/kuasar-sandbox/workbench:v0.1.6` |
| Demo SDK | `e2b==2.25.1`（由 `test/demo/requirements.txt` 锁定） |

方式 A 会下载这些资产（本机实测大小）：

```
SHA256SUMS                                          1.5 KB
platform-release-v0.1.6.tar.gz                    197.8 MB
accelerator-v0.1.6-linux-x86_64.tar.gz             37.2 MB
connector-v0.1.5-linux-x86_64.tar.gz                5.0 MB
orchestrator-v0.1.6-linux-x86_64.tar.gz            78.7 MB
sandboxer-v0.1.6-linux-x86_64.tar.gz               15.5 MB
sandbox-runtime-x86_64-v0.1.6.tar.gz               31.6 MB
vmlinux-x86_64-v0.1.4.tar.gz                        5.4 MB
workbench-x86_64-v0.1.6.tar.gz                   1263.8 MB   （Docker 镜像归档，勿解包）
```

磁盘占用参考（解包 + 镜像导入后）：下载缓存 ≈ 1.6 GB，解包树 ≈ 0.9 GB，
workbench 实例状态 ≈ 1.2 GB，源码构建状态（方式 B）≈ 3.7 GB。

---

## 1. 宿主前置条件

| 项 | 要求 | 本机实测值 |
|---|---|---|
| 架构 | x86_64 或 aarch64（原生，非模拟） | x86_64 |
| 内核 | 支持 KVM、BPF/JIT、TC、userfaultfd、TAP、vsock、overlayfs | `6.18.40.1-microsoft-standard-WSL2` |
| `/dev/kvm` | 可读写 | 存在，`kvm` 组 rw |
| systemd | 作为 PID 1 | 是（`/run/systemd/system`） |
| cgroup | v2，含 cpu/memory/pids | 是 |
| Docker | **本地 rootful 原生引擎 + Unix socket** | 见第 3.1 节（本机需自建） |
| Python | 3.9+（宿主）；Demo 用固定 3.12 环境 | 3.12.3 |
| sudo | 非交互（`sudo -n`） | 见第 3.2 节 |
| 磁盘 | 建议 ≥ 8 GB 可用 | 充足 |

自检脚本（全部通过即满足）：

```bash
# KVM 可用性
python3 - <<'PY'
import fcntl, os
with open('/dev/kvm','rb+',buffering=0) as k:
    assert fcntl.ioctl(k,0xAE00)==12, 'KVM API version'
    vm=fcntl.ioctl(k,0xAE01,0); os.close(vm)
print('KVM OK')
PY

# 宿主工具
for t in curl tar sha256sum openssl ip iptables flock setsid timeout mkfs.ext4 sqlite3 python3; do
  command -v "$t" >/dev/null || echo "MISSING: $t"
done

# systemd / cgroup
[ -e /run/systemd/system ] && echo "systemd OK"
cat /sys/fs/cgroup/cgroup.controllers
```

> 本机 `sqlite3` 起初缺失（Demo 需要），已用 `sudo apt-get install -y sqlite3` 安装。

---

## 2. 安装（一键流程）

所有命令在仓库根目录执行：

```bash
cd /home/cyx/Codes/kuasar/kuasar-sandbox

# 步骤 1：宿主准备（幂等）——原生 Docker、免密 sudo、ip_forward、出网修复
./demo.sh setup

# 步骤 2：下载并校验 release-v0.1.6，解包，导入 workbench 镜像（约 1.6 GB）
./demo.sh download

# 步骤 3：创建并启动 workbench 私有系统环境（6 vCPU / 6 GiB）
./demo.sh init

# 步骤 4：在 workbench 内离线准备 Demo 输入（锁定 wheel + helper）
./demo.sh prepare

# 步骤 5：运行 Demo
./demo.sh quick     # 短流程（约 1 分钟）：建模板→起微VM→exec/files→网络→pause/resume→kill
./demo.sh full      # 完整流程：在上面基础上再加模板 fan-out 与一次性 migration
```

成功标志：

```
quick → ══════ quick start complete — built, created, ran, paused/resumed, and killed via the e2b Python SDK ══════
full  → ══════ demo complete — built (full 3-phase pipeline → snapshot), created, ran, served the built site,
        paused/resumed, forked-to-template, migrated, killed — all via the e2b Python SDK ══════
```

`setup`、`init`、`prepare`、`download` 都是**幂等**的，失败后可安全重跑。

---

## 3. 本机专属的三处准备（`setup` 自动完成，这里说明原因）

### 3.1 使用原生 Docker Engine（不能是 Docker Desktop）

`workbench/workbench` 的 `host_check` 是硬判据：

```python
info['KernelVersion'] == platform.release() and 'Docker Desktop' not in info['OperatingSystem']
```

本机 WSL 集成里 Docker Desktop 占用默认 socket，因此 `setup` 会：

- `apt-get install docker.io containerd`；
- 禁用发行版默认的 `docker.service` / `docker.socket`；
- 建立独立服务 `docker-native.service`，监听 `unix:///run/docker-native.sock`（已 enable，开机自启）；
- 之后所有命令通过 `DOCKER_HOST=unix:///run/docker-native.sock` 使用它。

Docker Desktop 不受影响，可继续用于其它用途。

### 3.2 配置免密 sudo

Demo 的 prepare/run 使用 `sudo -n`，且 `prepared.py` 要求 `euid==0`。
`setup` 读取仓库内的 `env`（内容形如 `export SUDO_PASSWORD=...`）并写入
`/etc/sudoers.d/90-cyx-nopasswd`（`cyx ALL=(ALL) NOPASSWD: ALL`）。已具备免密 sudo 时自动跳过。

### 3.3 Docker daemon 自身走 Clash 代理

本机出网依赖 Clash（运行在 Windows 宿主 = WSL 默认网关），原生 dockerd 直连会
`connection reset by peer`。`docker-native.service` 的启动脚本
`/usr/local/libexec/docker-native-launch.sh` 在**启动时动态解析默认网关**并注入
`http_proxy/https_proxy`（默认端口 7897，`CLASH_PROXY_PORT` 可覆盖），避免 WSL 重启后网关变化失效。

---

## 4. 安装后的日常使用

```bash
cd /home/cyx/Codes/kuasar/kuasar-sandbox

./demo.sh status   # 查看 数据根/版本/镜像/实例/容器/出网规则/ip_forward
./demo.sh quick    # 重跑短 Demo（会自动重启实例并停掉旧存储层）
./demo.sh full     # 重跑完整 Demo
./demo.sh stop     # 停 Demo 存储层 + 停 workbench 实例（保留数据）
./demo.sh reset    # 删除 workbench 内 Demo 数据
./demo.sh cleanup  # 停并删除 workbench 容器（保留 work/output 目录）
```

进入 workbench 交互 shell（需 TTY）：

```bash
python3 /home/cyx/kuasar-deploy-data/release-v0.1.6/workbench/workbench \
  --root /home/cyx/kuasar-deploy-data/kuasar-workbench-state \
  --name "$(cat /home/cyx/kuasar-deploy-data/.wb-name)" exec
```

注意：Demo 的持久存储层（Registry/VersityGW）**独占宿主固定端口 5000/5050**，
同一时刻只能有一份在跑；`quick/full/src-demo` 会先自动停掉旧存储层。

---

## 5. 方式 B：源码安装（需要改代码时）

### 5.1 一次性准备

```bash
cd /home/cyx/Codes/kuasar/kuasar-sandbox
./demo.sh src-clone   # 在 ../ 下 clone 上述五个组件仓库（按锁定 tag）
./demo.sh src-build   # 从源码构建全部产品 → bin/x86_64/
./demo.sh src-status  # 查看组件检出与产物
```

源码目录结构（`Makefile` 的 `ORG := $(CURDIR)/..` 约定）：

```
/home/cyx/Codes/kuasar/
├── kuasar-sandbox/   ← 本仓库（构建入口）
├── orchestrator/  sandboxer/  accelerator/  connector/  guest-runtime/
```

`src-build` 在 **workbench `--mode build`** 实例里编译（把 `/home/cyx/Codes/kuasar` 挂到 `/src`，
容器自带 Go 1.26 / Rust / clang / mkfs.erofs），因此宿主**无需**安装整套工具链。
冷构建本机约 **30–40 分钟**（主要是 Rust 的 cloud-hypervisor 与 C++ 的 librocksdb）。

> **关于 fork**：`src-clone` 只是一次性引导，硬编码官方 URL 与锁定 tag，**不认你的 fork**；
> 目录已存在时会直接跳过，不会刷新或覆盖。若你在自己的 fork 分支上改代码，请自己把六个
> 兄弟目录的 `origin` 指到 fork、`upstream` 指到 `kuasar-sandbox`，然后直接 `src-build`——
> 构建只编译 `../` 下的源码，不看 remote。详见 `DEPLOY.md` §4.1。

### 5.2 构建期的三处本机适配（`src-build` 已自动处理）

1. **Go 模块**：直连 `proxy.golang.org` 在本机超时 → 设为 `GOPROXY=https://goproxy.cn,direct`。
2. **Cargo 源**：`static.crates.io` 在本机被限速（实测 ~58 KB/s；cloud-hypervisor 有约 300 个
   crate）→ 换用 `sparse+https://rsproxy.cn/index/`；其 git 依赖走 GitHub 直连。
3. **播种非代码产物**：从 release 播种内核 `vmlinux`（与代码无关，冷编数分钟）以及
   `zot`/`versitygw`（避免从被限速的 GitHub Release CDN 重复下载）。

### 5.3 跑 Demo（源码产物）与改码循环

```bash
./demo.sh src-demo quick   # 对源码产物跑短 Demo
./demo.sh src-full         # 对源码产物跑完整 Demo

# 改代码 → 重建 → 再跑
cd /home/cyx/Codes/kuasar/orchestrator && git switch -c my/change && $EDITOR ...
cd /home/cyx/Codes/kuasar/kuasar-sandbox
./demo.sh src-build        # 增量重建（实测单仓库改动约 11 秒）
./demo.sh src-demo quick
```

`src-demo` 走官方 native-source 路径：直接在宿主用 `bin/x86_64/` 跑
`demo_prep.sh`+`demo_e2b.sh`，会自动创建锁定版 `e2b` 的 `.demo-venv`、检查宿主工具并确保
`ip_forward`/出网。

### 5.4 清理

```bash
./demo.sh src-clean        # 只删叶子产物（保留依赖构建、Go/Cargo 缓存、内核种子）
./demo.sh src-full-clean   # 连依赖构建一起删（下次为冷构建）
```

---

## 6. 验证清单（安装成功的判据）

逐阶段断言（完整表见 `test/demo/DEMO.md`）：

| # | 阶段 | 期望结果 |
|---|---|---|
| 1 | Node stack | Conductor/Proxy 就绪；eBPF vSwitch + NAT 起来 |
| 2 | Tenant | ManifestKey + 派生 API key 下发 |
| 3 | Build | 3 阶段流水线 → 快照模板 `kind=snp`、ID 形如 `e2b-snp-<base64(manifest://…)>` |
| 4 | Create | 真实 Cloud Hypervisor MicroVM 经 Proxy 可用 |
| 5 | Data | `commands.run` / `files` 返回断言内容 |
| 6 | Network | 端口转发可达 built 页面；**访客 NAT 出网返回 HTTP 响应** |
| 7 | State | `pause` → `connect` 后数据存活 |
| 8 | Fan-out（full） | `export-sandbox --to-template` 后新建子沙箱继承状态 |
| 9 | Migration（full） | `connect(headers=migration-token)` 一步 import+resume |
| 10 | Destroy | `kill` 后资源回收 |

快速自证：

```bash
./demo.sh status                       # 应显示 release 存在、instance running=yes、egress 规则在
./demo.sh quick && echo "QUICK PASS"
```

日志位置（宿主侧）：`/home/cyx/kuasar-deploy-data/kuasar-workbench-state/<name>/work/kuasar-demo-run/results/`。

---

## 7. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `refusing Docker Desktop` | `DOCKER_HOST` 指向了 Desktop | `export DOCKER_HOST=unix:///run/docker-native.sock` |
| dockerd 拉镜像 `connection reset` | daemon 未走代理 | 检查 `docker-native-launch.sh` 解析到的网关与 `CLASH_PROXY_PORT` |
| 访客出网超时（`egress HTTP ...` 失败） | `1.1.1.1` 出网 DNAT 规则缺失 | `./demo.sh setup`（`quick/full` 也会自动补） |
| `127.0.0.1:5000 is already in use by a process not owned by this Demo` | 另一份存储层仍在跑 | `./demo.sh stop`；脚本在运行前会自动清理 |
| `Cannot connect to the Docker daemon`（方式 B） | `sudo` 丢了 `DOCKER_HOST` | 用 `sudo -n env ... DOCKER_HOST=...`（脚本已处理） |
| `src-build` 卡在 cargo `Updating crates.io index` | 未走镜像 | 确认 build 实例内 `~/.cargo/config.toml` 指向 `rsproxy.cn` |
| `src-build` 拉 Go 模块超时 | 直连 `proxy.golang.org` | 确认 `GOPROXY=https://goproxy.cn,direct` |
| 容器被 OOM | 本机仅 ~7.4 GiB | 降 `WB_MEMGIB`（如 `WB_MEMGIB=5 ./demo.sh quick`），或关闭其它大内存进程 |

---

## 8. 卸载 / 回滚

```bash
cd /home/cyx/Codes/kuasar/kuasar-sandbox
./demo.sh cleanup                                          # 停并删 workbench 容器（保留 work/output）

# 可选：彻底移除
docker image rm ghcr.io/kuasar-sandbox/workbench:v0.1.6     # 约 3.5 GB
sudo rm -rf /home/cyx/kuasar-deploy-data                    # 下载缓存 + 解包 + 实例/构建状态
sudo rm -f /etc/sudoers.d/90-cyx-nopasswd
sudo iptables -t nat -D PREROUTING -d 1.1.1.1 -p tcp --dport 80 -j DNAT --to-destination 1.0.0.1:80
sudo systemctl disable --now docker-native.service          # 若不再需要原生引擎
# 方式 B 追加：删除源码目录与产物
sudo rm -rf /home/cyx/Codes/kuasar/{orchestrator,sandboxer,accelerator,connector,guest-runtime}
rm -rf /home/cyx/Codes/kuasar/kuasar-sandbox/{bin,build,.demo-venv}
```

---

## 9. 安装记录（本机实测参考）

| 阶段 | 观测 |
|---|---|
| 下载 + 校验 + 解包约 2.9 GB | 数分钟（受网络影响） |
| 导入 workbench 镜像（1.26 GB tar.gz） | 约 2 分 40 秒 |
| `init`（启动 systemd 私有环境 + KVM/BPF/TUN/UFFD 预检） | 约 20 秒 |
| `prepare`（离线安装锁定 wheel） | 约 30 秒 |
| `quick` Demo | 约 1 分钟 |
| `full` Demo | 约 1–2 分钟 |
| 方式 B 冷构建（全部产品） | 约 30–40 分钟 |
| 方式 B 增量重建（改一个 Go 文件） | 约 11 秒 |

---

## 10. 参考

- `DEPLOY.md` —— 本仓库的部署指南（含本环境四处适配的详细说明与官方文档差异对照）
- 官方文档（本仓库内）：`docs/quickstart.md`、`docs/download.md`、`workbench/README.md`、`test/demo/DEMO.md`
- 版本选择权威来源：`releases/release.yaml`
- 生产部署（超出本指南范围）：`docs/deployment.md`
- 六个组件仓库导览（每个仓库做什么、产出什么、文档在哪）：`../README.md`
