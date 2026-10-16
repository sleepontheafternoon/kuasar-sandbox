# Manifest 模板:从制作指令到数据流动

本文说明 Kuasar Sandbox 里**镜像如何变成一个 Manifest 模板**,以及之后
**数据是如何流动的**。内容分两部分:

1. **制作指令** —— 从最底层的 `flatten-ctl` / `manifest-ctl`,到用户层的
   `Template.build(...)`,哪些命令在做什么。
2. **数据流动** —— 先给整体流转图,再结合 accelerator 的**关键代码**逐段讲解。

> 权威定义在组件仓库文档:`accelerator/docs/manifest.md`(Manifest 与内容寻址)、
> `accelerator/docs/store.md`(存储)、`accelerator/docs/cache.md`(缓存)、
> `guest-runtime/docs/flatten.md`(镜像展平)、`orchestrator/docs/node-build.md`(构建)。
> 配套阅读:[manifest-code-guide.md](manifest-code-guide.md) 从**代码结构**角度逐子包讲解
> `accelerator/pkg/manifest`(包布局、二进制形态、引用格式、存储后端、CLI)。
> 本文是"把这些串起来看一遍"的整合视图。

---

## 0. 先厘清两个概念

| 概念 | 是什么 | 谁拥有 |
|---|---|---|
| **镜像/数据字节** | 真实的文件系统内容(EROFS 等) | 字节本身 |
| **Manifest** | 这些字节的"目录":分块索引 + 洞表 + 封装的密钥表 | `accelerator/pkg/manifest` |

Manifest **不是另一种镜像格式**,它是**内容寻址存储的索引对象**。`manifest.md` 的
Non-goals 明确写道:

> Understanding Docker, OCI, EROFS or other high-level payload formats:
> the data layer handles **bytes and sparse geometry**.

所以"制作 Manifest 模板"= 把镜像字节**分块、加密、去重后存起来**,再生成一个
Manifest 作为句柄。

---

# 第一部分:制作 Manifest 模板的指令

## 1. 最底层:两步走

### 1.1 第 1 步 —— 拉取并展平:`flatten-ctl export`

作用:**拉取 registry 镜像(或读 docker-archive / 本地 rootfs)→ 合并所有层 →
生成一个确定性的 EROFS payload → 打包成 tarstream artifact**,并把 OCI 运行时配置
(Entrypoint/Env/WorkingDir)以尾部 ZIP 内嵌进去。

```bash
# 从 registry 拉取并展平成 .img(含 EROFS + 内嵌 config.json)
flatten-ctl export --output nginx.img nginx:1.27

# 从 docker save 归档展平
docker save myapp:v1 | flatten-ctl export --output my-app.img
flatten-ctl export --output my-app.img ./my-app.tar

# 从一个已就绪的 rootfs 目录展平
flatten-ctl export --skip-mounts --tmpdir /run/flatten-export \
    --runtime-config config.json --output /run/flatten-export/host.img /
```

也可以**一步到位**:`--upload` 会在展平后立刻进入下一阶段(ingest),直接打印
manifest key(此时临时 artifact 会被丢弃):

```bash
flatten-ctl export --upload --manifest-config manifest.yaml --config flatten.yaml \
    --output app.img nginx:1.27
```

为什么必须展平(`flatten.md` §1.1):

- 客户机是极简 VM,**没有 containerd、没有 overlayfs 层堆叠**;它通过
  vhost-user-blk 拿到的必须是**一块已拼好的只读盘**,而不是"N 层 tar"。
- EROFS **只读且不可变**,与 Manifest 的分块/内容键寻址天然契合。
- 展平强调**确定性**(`-T0 --ignore-mtime` 等):同样的源 + 工具 + 配置 ⇒
  **逐字节相同的 payload** ⇒ 同样的分块 ⇒ 同样的 content key ⇒ 去重与模板 ID 可复现。

#### 实现:这一步在代码里到底做了什么

`flatten-ctl` 只是薄壳;真正的逻辑在 **accelerator** 仓库
(`accelerator/pkg/{remote,flatten,image}`),guest-runtime 通过 `go.mod` 依赖它。

```
guest-runtime/cmd/flatten-ctl/main.go     CLI 外壳:参数解析、输入分类、打包 artifact
   └── accelerator/pkg/remote             拉取(pull)
   └── accelerator/pkg/flatten            合并层 + 生成 EROFS
   └── accelerator/pkg/image              EROFS superblock / 追加 config ZIP
   └── accelerator/pkg/manifest           摄入(ingest,见 §5)
```

`runRemoteFlatten` 是 registry 源的入口:

```go
res, _ := cfg.Resolve(ctx, ref)        // 解析引用,选平台,钉死不可变 digest
cache, cleanup, _ := cfg.OpenCache()   // 本地 OCI-layer 缓存
src, _ := cfg.Pull(ctx, res, cache)    // 拉取各层(命中的走缓存)
flatten.Build(src, outputPath, opts)   // 合并 + EROFS + 内嵌 config
```

**① 解析引用并钉死版本**(`remote.Resolve`)。包注释说明了原因:

> Resolve parses ref, contacts the registry, selects the configured platform
> from an index (or takes the single manifest), and returns the pinned
> image-manifest digest. Resolving a moving tag here is what lets callers
> print and persist an immutable **repo@sha256** for reproducibility.

即 `python:3.12-slim`(会移动的 tag)先变成 `repo@sha256:<digest>`,之后一切基于该 digest
——这是"确定性"的起点,也是日志里 `resolved: …@sha256:139b14…` 的来源。

**② 拉取各层**(`remote.Pull`),三段式:

```go
// Pass 1: 先探每层 digest,查明哪些是缓存未命中(进度分母只算未命中)
for i, l := range layers { d, _ := l.Digest(); if !cache.Has(d) { misses = append(misses, i) } }
// Pass 2: 并发下载未命中的层,并发度 = PullJobs
sem := make(chan struct{}, c.pullJobs())
// 每层落本地内容寻址缓存;应用时再 decompress(gzip 层)
```

**③ 合并层**(`flatten.Build` 的 Step 1 → `applyLayerTar`)。**不是 overlay 挂载**,
而是按顺序把每层 tar 写进同一个 rootfs 目录,并实现 OCI 白化语义:

```go
name := filepath.Clean(hdr.Name); base := filepath.Base(name)

// 不透明白化(.wh..wh..opq):清空整个目录
if base == ".wh..wh..opq" { clearDirectory(filepath.Join(rootfsDir, dir)); continue }
// 文件白化(.wh.<name>):删除该条目
if strings.HasPrefix(base, ".wh.") {
    os.RemoveAll(filepath.Join(rootfsDir, dir, strings.TrimPrefix(base, ".wh."))); continue
}
```

按 `Typeflag` 落地:目录 `MkdirAll`;普通文件**先 `os.Remove(target)` 再写**(上层覆盖下层);
软链/硬链同理。属主与权限经 `applyOwnerMode` 保留,原因见其注释:

> Preserving the image's real uid/gid requires root (**CAP_CHOWN**) ... e.g. `/tmp`
> stays 1777 and `/home/<user>` stays user-owned, so a non-root guest user can
> write to its home.

所以 `runExport` 在**拉取前**就先检查权限,避免"拉了几分钟才在 chown 处失败":

```go
if !dirSrc { if err := flatten.RequireOwnershipCap(); err != nil { return err } }
```

**④ 确定性归一化**(`normalizeTimestamps`):把所有 mtime 抹到 epoch,软链跳过。

```go
epoch := unixEpoch
filepath.Walk(rootfsDir, func(path string, info os.FileInfo, err error) error {
    if info.Mode()&os.ModeSymlink != 0 { return nil }   // Chtimes 会跟随软链,故跳过
    return os.Chtimes(path, epoch, epoch)
})
```

**⑤ 生成确定性 EROFS**(`buildEROFS` → `mkfs.erofs`),参数各有其意:

```go
args := []string{
    "-Ededupe",                                   // 镜像内文件去重
    "--chunksize=4096",                           // 分块布局:元数据 7.6MiB→0.6MiB,稳定数据块偏移
    "-T0",                                        // 固定时间戳(epoch)
    "-b4096", "-x-1",                             // 4K 块;关闭 xattr
    "-U", "00000000-0000-0000-0000-000000000000", // 固定 UUID
    "--quiet",
}
```

注意:**不启用压缩**(注释:*No compression: raw bytes enable CDC dedup*)。
因为 manifest 层要按内容寻址去重,压缩会引入实现差异、破坏"同内容 ⇒ 同字节"。

**⑥ 内嵌 OCI 运行时配置**(Step 4):`image.AppendConfigZip` 把 config 投影成
**STORED-mode(不压缩)ZIP**,追加在 EROFS 之后。注释解释了为何可行:

> EROFS mount/read remains correct because the EROFS image's extent is described
> in its superblock; the ZIP trailer is addressable independently.

**⑦ 打包成 tarstream artifact**(`packImageArtifact`)。每次 export 都先写一个**裸 EROFS**
scratch 文件(`mkfs.erofs` 需要可寻址输出),然后:

```go
holes, _ := sparse.ProbeHoles(f)                  // 探测 EROFS 的稀疏洞
src, _ := sparse.NewSource(f, size, holes)        // 带洞的稀疏源
tail, boundary, _ := tailzip.Read(f, size, ...)   // 读回刚追加的 config ZIP
// 用 tarstream 把 "EROFS + 尾部 ZIP" 写成条目名 "image" 的载体
tarstream.WriteTo(ctx, w, "image", src)
```

**这里的关键衔接**:`sparse.ProbeHoles` 探测出的洞,会一路传递到 §5 的 ingest
——变成 Manifest 的 **Hole 表**,于是"展平后镜像里的空洞"在存储层"不读也不存"。

产物形态与日志对应:

```
[ EROFS 文件系统 ][ appended STORED ZIP(config.json) ]   ← 打包为 tarstream(payload "image")
· EROFS image: 118.0 MiB                                  ← 裸 EROFS 大小(runExport 打印)
```

### 1.2 第 2 步 —— 摄入为 Manifest:`manifest-ctl store`

作用:把 tarstream artifact **分块 → 收敛加密 → 存入 store**(带去重)→ 生成
Manifest → 上传 → **stdout 打印 64 位十六进制 content key**。

```bash
# artifact 文件 → Manifest key
MKEY=$(manifest-ctl store --manifest-config manifest.yaml app.img)

# 也可以从 stdin
cat app.img | manifest-ctl store --manifest-config manifest.yaml > app.key
```

拿到的 `MKEY` 就是句柄,可以直接包装成引用:

```
manifest://<MKEY>          # 恰好一个 64 位小写 hex
```

### 1.3 验证与检查(可选)

```bash
manifest-ctl info   manifest://<MKEY>   # 打印元数据(不解密钥表,不需客户密钥)
manifest-ctl verify manifest://<MKEY>   # 逐块取回解密,全量校验(强制 SHA)
manifest-ctl load   manifest://<MKEY>   # 读回逻辑数据(tarstream)
manifest-ctl get-manifest <MKEY>        # 取回原始 Manifest 字节
```

### 1.4 所需的配置(`manifest-config.yaml`)

`manifest-ctl store/load/...` 需要一个 YAML(经 `--manifest-config` 或
`$MANIFEST_CONFIG`,**无自动发现**):

```yaml
manifest:
  key: ""                 # 32 字节客户密钥(hex)。可留空,改用 $MANIFEST_KEY(优先)
store:
  endpoint: 127.0.0.1:7100 # store-ctl 的 gRPC(写/直读需要)
cache:
  endpoint: 127.0.0.1:7070 # cache-ctl 的 wire(读走缓存;留空则直连 store)
chunker:
  mode: cdc               # cdc(FastCDC) | fixed
  cdc: { min: 128KiB, avg: 512KiB, max: 1MiB }
crypto:
  chunk: aes              # 仅支持 aes
  manifest: aes           # 仅支持 aes
```

要点(**来自 `manifest.md` §3.1**):

- `manifest.key` 是**客户密钥(ManifestKey)**,它**只封装 key 表**,**不派生**块密钥。
- 密钥优先级:**非空 `$MANIFEST_KEY` > YAML `manifest.key`**;这样密钥可不落在共享文件里。
- 丢失客户密钥 ⇒ 该 Manifest 的 key 表**无法解封** ⇒ 数据不可恢复。

## 2. 用户层:其实你不必手敲上面这些

用**未修改的 E2B SDK** 时,`Template.build(...)` 会在**构建沙箱**里自动完成
"拉取 → 展平 → 摄入 → 发布",并返回一个可移植的模板 ID:

```python
from e2b import Template

tpl = (Template().from_image("python:3.12-slim")
       .run_cmd("mkdir -p /app && echo hi > /app/x")
       .set_start_cmd("python3 -m http.server 8000", wait_for_timeout(2000)))

info = Template.build(tpl, name="my-app", cpu_count=2, memory_mb=6144)
# info.template_id 对应的"已发布模板 ID"形如 e2b-snp-<base64(manifest://<hex>)>
```

对应关系(`node-build.md` 的发布矩阵,`manifest=false` 的默认路径):

| 产物 | 默认落点 |
|---|---|
| IMG(展平后的冷镜像) | Manifest Store |
| 顶层 E(冷 Sandbox) | Manifest Store |
| S(内存快照)+ 增量 Δ | Manifest Store(或 `remote.manifest=true` 时落 named location) |

日志里你会看到这几步(来自一次真实运行):

```
import: pulling + flattening 169.254.169.254:5000/e2b/base@sha256:139b14…
· EROFS image: 118.0 MiB
· publishing final image to the Manifest store
· published template checkpoint snapshot: manifest://6814e001a5c331d0…
```

而最终得到的**模板 ID 是自描述的**(`node-build.md`):

> Persistent IDs are **self-describing**. Their payload is canonical `manifest://`…

即:`e2b-snp-bWFuaWZlc3Q6Ly9jNDhm…` 用 base64 解开就是
`manifest://c48fc29c1aebefa63e32db806d8f9725d36f7417d5628299150c64a2c758b16d`。

## 3. 回过头看一眼:一次完整流水线

```
registry 镜像 python:3.12-slim
   │  flatten-ctl export          拉取 + 合并层 → 确定性 EROFS(+ 内嵌 config.json)
   ▼
EROFS payload (tarstream artifact)
   │  manifest-ctl store          分块 → 收敛加密 → 去重 → 存 chunk → Marshal Manifest
   ▼
chunk 对象 + Manifest 对象
   │  ContentKey = SHA256(物理信封)
   ▼
manifest://<hex>  ── base64 ──▶  e2b-snp-<...>   （模板 ID / 沙箱句柄）
```

---

# 第二部分:数据流动

## 4. 整体流转图

```
Agent / E2B SDK / 平台 API
              │
        orchestrator                    控制面、集群编排（node-ctl conductor/proxy）
              │
        sandboxer                       跑单个 MicroVM（sandbox-ctl + cloud-hypervisor）
        ├── accelerator                 存储 / 镜像 / 缓存  ★ 本文主角
        ├── connector                   网络（eBPF）
        └── guest-runtime               客户机内核 / 镜像
              │
   KVM / 本地文件 / NAS / 对象存储 / 网络
```

聚焦到"一个镜像变成 Manifest 模板,再被还原"这条链:

```
 registry 镜像
        │  ① flatten-ctl：拉取 + 展平
        ▼
   EROFS 镜像 (118 MiB)            ← 逻辑数据（字节流）
        │  ② 发布：sparse.Source（带 Hole/Zero 几何）
        ▼
   ┌─ store/chunk/G1/<aa>/<bb>/<cipherhash>   每块一个物理对象（加密 + 去重）
   └─ store/manifest/G1/<aa>/<bb>/<key>       Manifest 对象（分块索引 + 封装的密钥表）★
        │  ③ ContentKey = SHA256(物理信封)
        ▼
   manifest://<64-hex>  →  e2b-snp-<base64>    ← 对外模板 ID
        │  ④ Sandbox.create 时按 key 还原
        ▼
   fetch：解 Manifest → 解 key 表 → 按需取块 → 解密 → 微VM 启动
```

下面结合**关键代码**逐段讲解这条链。

## 5. 写侧:ingest 管线

`accelerator/pkg/manifest/ingest/ingest.go` 的包注释直接给出了流水线:

```
sparse.Source → Chunk → Encrypt → Store.Put(去重) → Marshal Manifest → Store.Put(manifest)
```

### 5.1 一次 ingest = 一次写准入

```go
admission, err := i.store.AdmitWrite(ctx)      // 拿到一个 generation + salt
salt, err := i.mixSalt(admission.Salt)         // 可选 extra_salt 混入
```

**一次 `Ingest` 只调一次 `AdmitWrite`**,该次 ingest 的所有块 + 最终 Manifest
都复用这一个 `admission`(同一 generation、同一 salt 域)。

### 5.2 稀疏源:Hole 与 Zero 的处理

主循环对源做**严格单向**扫描。关键片段:

```go
run, _ := src.RunAt(cursor, size-cursor)
kind, end := run.Kind(), run.End()
if kind == sparse.Hole {
    // 记录 hole 区间；不读、不分块
    m.Holes = append(m.Holes, sparse.Extent{Offset: cursor, Size: end - cursor})
    cursor = end
    continue
}
// 非 hole 段(Data|Zero 连续)作为一个 segment 交给 chunker
```

- **Hole**:只记录几何,不读数据 → 变成 Manifest 的 hole 表
- **Zero**:作为合成零字节喂给 chunker(不 `ReadAt`),`cr.IsZero` 为真时:

```go
if cr.IsZero {
    oc.isZero = true          // 仅置标志
    emitProgress(cr.Size)
    return nil                // 不入 jobs、不加密、不上传
}
```

这就解释了"逻辑 6 GiB 但物理只有 228 MB":**大部分是 Hole(5.8 GiB)与 Zero**,真实数据块才需要存。

### 5.3 加密与去重(每个数据块)

worker 池里对每个块:

```go
ciphertext, hash, key, err := i.enc.EncryptChunk(wctx, salt, j.data)
...
ck := store.ContentKey(hash)
isNew, err = i.store.Put(wctx, admission, store.PartitionChunk, ck, ciphertext)
```

`EncryptChunk`(`crypto/aes.go`)做的事:

```go
// 1) 选编码:RAW 或 Snappy(固定规则,非配置)
format := ChunkFormatAESRaw
payload := plaintext
if compressionBeneficial(uint64(len(plaintext)), uint64(len(encoded))) {
    format = ChunkFormatAESSnappy
    payload = encoded
}
// 2) 收敛密钥:key = SHA256(salt || plaintext)
key := DeriveKey(salt, plaintext)
// 3) 物理对象 = [格式位] || AES-256-CTR(key, IV=0, payload)
object := make([]byte, 1+len(payload))
object[0] = format
cipher.NewCTR(block, iv[:]).XORKeyStream(object[1:], payload)
hash := sha256.Sum256(object)      // ContentKey = SHA256(物理对象)
```

- **同明文 + 同 salt ⇒ 同密文 ⇒ 同 `ContentKey` ⇒ `Put` 命中已有对象 ⇒ 去重**
  (`Put` 返回 `isNew=false`,服务端跳过上传 body)
- 物理格式:`0x01`=RAW,`0x02`=Snappy(前面实测抽到的第一个 chunk 首字节就是 `0x02`)

### 5.4 确定性:按文件顺序组装,不受并发完成顺序影响

加密/上传是**有界并发**的,但 Manifest 的条目**严格按文件顺序**从 outcomes 组装:

```go
// Assemble the manifest strictly in file order from outcomes. This is what
// preserves manifest determinism (same input -> same key) despite out-of-order
// store.Put completion.
for _, oc := range outcomes {
    var entry codec.ChunkEntry
    entry.Offset = oc.offset
    entry.Size   = oc.size
    if oc.isZero {
        entry.IsZero = true              // 零块:无 CiphertextHash
    } else {
        entry.CiphertextHash = oc.ck     // 非零块:记密文哈希
        nonZeroKeys = append(nonZeroKeys, oc.key)
    }
    m.Entries = append(m.Entries, entry)
}
```

这是"**同样的输入 ⇒ 同样的 Manifest content key**"的关键:**并发只影响上传顺序,不影响索引顺序**。

### 5.5 封 key 表 → Marshal → 写 Manifest

```go
// 只有非零块进封装的密钥表(零块无槽位)
flatKeys := /* nonZeroKeys 拍平 */
sealed, err := i.enc.SealKeyTable(customerKey, flatKeys, codec.BuildAAD(m))

blob, err := codec.Marshal(m, sealed)                 // 物理信封 ["MANI"][enc][payload]
manifestKey := store.ContentKey(sha256.Sum256(blob))   // Manifest 自己的 ContentKey
_, err = i.store.Put(ctx, admission, store.PartitionManifest, manifestKey, blob)
res.ManifestKey = manifestKey                          // 就是对外句柄
```

**关键点**:

- `SealKeyTable` 用**客户密钥 AES-GCM** 封装"非零块的密钥表",AAD 绑定 Manifest 结构(`BuildAAD`)——**密钥表被篡改会解封失败**。
- Manifest 自身也是内容寻址对象:`manifestKey = SHA256(物理信封)`,与块用同一套寻址。
- 调用者**永远看不到序列化字节**,只拿到 `ManifestKey`。

### 5.6 五个环节:分块 → 收敛加密 → 去重 → 存 chunk → Marshal Manifest

把 §5.1–§5.5 压成一条线,逐环节对应到代码:

```
sparse.Source ──① 分块──▶ Chunk ──② 收敛加密──▶ 密文对象
                                     │
                    ③ 去重(ContentKey 已存在?)
                                     │
                          ④ store.Put(chunk 分区)
                                     │
                    ⑤ Marshal Manifest → store.Put(manifest 分区) → ManifestKey
```

**① 分块(`chunker.Chunker`)**

```go
type Chunker interface {
    Chunk(r io.Reader, cb Callback) error
    Info() Info
}
type ChunkResult struct { Offset uint64; Size uint32; Data []byte; IsZero bool }
```

- 两种模式:`cdc`(FastCDC,默认)或 `fixed`;由 `chunker.mode` 选。
- FastCDC 用 **Gear 滚动哈希**找边界:`hash = (hash << 1) + gearTable[b]`,配
  `min/avg/max`(默认 128K/512K/1M)和**非对称归一化掩码**(phase-1 抑制早切、phase-2 抑制强制切)。
- **普通源**返回 `Data`;**全零段**返回 `IsZero=true`(由 ingest 合成零字节喂入,不 `ReadAt`)。
- 洞**不经过 chunker**:ingest 主循环遇到 `sparse.Hole` 直接记洞表并跳过(见 §5.2)。

**② 收敛加密(`crypto.AESChunkEncryptor.EncryptChunk`)**

```go
ciphertext, hash, key, err := i.enc.EncryptChunk(ctx, salt, data)
```

```go
// crypto/convergent.go —— 密钥由 salt+明文派生(不是客户密钥!)
func DeriveKey(salt [32]byte, plaintext []byte) [32]byte {
    h := sha256.New(); h.Write(salt[:]); h.Write(plaintext); return ...
}
```

```go
// crypto/aes.go —— 选编码、派生密钥、加密、算物理哈希
format, payload := ChunkFormatAESRaw, plaintext
if compressionBeneficial(uint64(len(plaintext)), uint64(len(encoded))) {
    format, payload = ChunkFormatAESSnappy, encoded      // 仅当 CompressionBeneficial:省≥4KiB 且编码≤75%
}
key := DeriveKey(salt, plaintext)
object := make([]byte, 1+len(payload)); object[0] = format
cipher.NewCTR(block, iv[:]).XORKeyStream(object[1:], payload)
hash := sha256.Sum256(object)                            // 物理对象哈希
```

物理对象:`0x01 || AES-256-CTR(key, IV=0, plaintext)` 或 `0x02 || …(snappy)`。

**③ 去重**:不是"先算再查表",而是直接用 `hash` 当 key 去 `Put`;由 store 判定是否已存在
(内容寻址 + generation 作用域)。`Put` 返回 `isNew`:

```go
ck := store.ContentKey(hash)
isNew, err := i.store.Put(ctx, admission, store.PartitionChunk, ck, ciphertext)
// isNew == false ⇒ 命中已有对象,服务端跳过上传 body
```

去重的**前提**是收敛加密:同明文 + 同 salt ⇒ 同密文 ⇒ 同 `ContentKey`(见 §9)。

**④ 存 chunk**(`store.Put`,`PartitionChunk`):对象落在
`<root>/chunk/<generation>/<hex前2>/<hex第3-4>/<完整hex>`(见 §8)。
可选能力 `OrderedChunkStoreWriter.PutChunkOrdered(ordinal)` 让本地串行 writer 按**镜像顺序**追加。

**⑤ Marshal Manifest**(§5.4–§5.5):索引**按文件顺序**组装(与并发完成顺序无关),封 key 表,
`codec.Marshal` 成信封,再以 `manifestKey = SHA256(物理信封)` 写入 `PartitionManifest`;
返回的 `ManifestKey` 就是 `manifest://<hex>`。

**为什么这个顺序是刚性的**:`分块`决定去重粒度 → `收敛加密`让去重成为可能 →
`去重`减少物理写入 → `存 chunk`固定寻址 → `Marshal`把"块列表 + 密钥表"固化成可复现的句柄。
任何一步不"确定",最终 key 都会漂移,去重与模板 ID 稳定性随之失效。

---

## 6. Manifest 对象的二进制形态(`codec/manifest.go`)

物理信封:

```
[4B "MANI"][1B encoding][payload]      encoding: 0x00 RAW | 0x01 Snappy
```

逻辑布局:

```
[Header 64B]
[ChunkEntry × N, 每条 56B]      offset u64 | plain_len u32 | flags u32 | cipher_hash[32] | 8B 保留
[hole × M, 每条 16B]            offset u64 | size u64
[SealedKeyTable 变长]           客户密钥封装的非零块密钥
```

**不变量**(`ValidateGeometry` 强制):数据条目与洞**恰好无缝、无重叠地铺满 `[0, ImageSize)`**。

实测(本文开头那次运行):

```
version: 1   image size: 6.0 GiB   chunk mode: cdc
chunk count: 375   zero chunks: 66   holes: 59
key table: 9917 bytes (sealed)
manifest size: 31926 bytes
```

## 7. 读侧:fetch 管线

`accelerator/pkg/manifest/fetch/fetcher.go`:

```go
func (f *fetcher) OpenManifest(ctx, manifestKey) (Stream, error) {
    result, blob, err := f.cache.OnDemandGetter().Get(ctx, store.PartitionManifest, manifestKey)
    ...
    mData := blob.Bytes()
    if f.verifyContent && sha256.Sum256(mData) != manifestKey {
        return nil, ... // 内容键不匹配(损坏/被篡改)
    }
    m, sealedKT, err := codec.Unmarshal(mData)   // 解析索引
    ...
}
```

随后:

1. **校验** `SHA256(物理 Manifest) == key`(`verifyContent=true` 时;`verify/import/export/repair` 路径强制开启)
2. **解析** header / chunk 索引 / hole 表
3. **解封 key 表**(`codec.UnsealKeys`,需要客户密钥)
4. 读某个偏移时:二分查 entry → 按 `cipher_hash` 经 **cache** 取块 → `DecryptChunkTo` 解密(必要时 Snappy 解压)

### 按需加载与分层覆盖

- `RunAt(offset)` **只查稀疏表/索引**,不读数据、不解密;真正 `ReadAt` 才并发取块。
- 明文块缓存:key 含 `CiphertextHash` + 解密密钥 + 明文大小;有 32 项 / 32 MiB 上限、5 秒空闲过期。
- **分层覆盖**(`fetch/layered.go`):

```go
// top → bottom 叠加:最上层有数据者服务;
// 声明为 hole(或越界)→ 落穿下层;IsZero 块不透明,不落穿;Size 取各层最大。
func NewLayered(layers ...Stream) Stream
```

这正是"**只读模板父层 + 每实例可写增量**"的实现。

## 8. 存储布局与代际(`pkg/store`)

```go
type Partition string
const (
    PartitionChunk    Partition = "chunk"
    PartitionManifest Partition = "manifest"
    PartitionBlob     Partition = "blob"     // 与 chunk/manifest 同机制,仅逻辑隔离
)
type ContentKey [32]byte
type WriteAdmission struct { Generation Generation; Salt [32]byte }
```

FS 后端的物理路径(`pkg/store/fs/fs.go`):

```
<root>/<partition>/<generation>/<hex前2>/<hex第3-4>/<完整hex>
```

实测:

```
.../store/manifest/G1/c4/8f/c48fc29c…b16d      31926 B   ← Manifest 对象
.../store/chunk/G1/a0/f8/a0f8a66f…632b             10355 B  首字节 0x02
```

`SaltForGeneration(g)`(域字符串 `accelerator-salt-v1`)是**唯一**的 salt 派生入口,
保证在线准入与离线写入落在同一 salt 域。

## 9. 两把"钥匙"在流动中的位置

| 环节 | 用哪个"键" | 作用 |
|---|---|---|
| 块加密 / 去重 | 收敛密钥 `SHA256(salt ‖ 明文)` | 同明文同 salt ⇒ 同密文 ⇒ 同 ContentKey ⇒ 去重 |
| key 表保护 | **客户密钥 ManifestKey** | 只封装 key 表;没有它无法解封(也就取不出块密钥) |
| 对外句柄 | `ContentKey = SHA256(物理对象)` | 就是 `manifest://…` 里那串 hex |

`manifest.md` §4.4 明确警告:**"客户密钥不外泄"本身不等于"存储内容不可推断"**
——同 salt 域会暴露"内容相等";安全边界须由部署方通过密钥/salt 访问控制来守。

## 10. 一句话总括

> `python:3.12-slim` →(flatten-ctl 拉取/合并层)→ 118 MiB 确定性 EROFS →
> (manifest-ctl ingest 分块/收敛加密/去重)→ 若干 chunk 物理对象 + 一个 31 KB Manifest →
> (SHA256)→ `manifest://c48fc…` →(base64)→ `e2b-snp-…` 模板 ID;`Sandbox.create` 时
> 再按此 key 反向 fetch、解密、按需加载。

整条链上:**Manifest 是"数据的目录",chunk 是"数据的页",store 是"书库",客户密钥是"目录的封条"**。

---

## 附:自己动手验证(不需要 KVM)

前提:有 `manifest-ctl`、`flatten-ctl`(同一聚合版本),以及一个 FS store 与 cache
(可用 Demo 的 `demo_prep.sh` 起,或按 `accelerator/docs/manifest.md §7` 起一个私有 FS store)。

```bash
# 1) 展平(用 docker save 归档最省事，无需 registry 凭证)
docker save alpine:3.20 | flatten-ctl export --output /tmp/alpine.img

# 2) 摄入为 Manifest
KEY=$(manifest-ctl store --manifest-config manifest.yaml /tmp/alpine.img)
echo "manifest://$KEY"

# 3) 检查与校验(无需客户密钥即可 info)
manifest-ctl info   "manifest://$KEY"
manifest-ctl verify "manifest://$KEY"

# 4) 读回
manifest-ctl load "manifest://$KEY" --output /tmp/alpine.roundtrip.img

# 5) 对比确定性:再展平一次同一镜像，观察是否得到同样的 key
docker save alpine:3.20 | flatten-ctl export --output /tmp/alpine2.img
KEY2=$(manifest-ctl store --manifest-config manifest.yaml /tmp/alpine2.img)
[ "$KEY" = "$KEY2" ] && echo "确定性 OK(同一镜像 ⇒ 同一 Manifest key)" || echo "key 不同"
```

> 说明:`flatten` 与 `store` 的产物大小取决于镜像内容、chunker 与 crypto 配置;
> 上面的"6 GiB 逻辑 / 228 MB 物理"是本文一次真实运行的观测,不是通用保证。
