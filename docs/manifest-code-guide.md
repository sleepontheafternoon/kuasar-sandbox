# accelerator 的 Manifest:代码结构导览

本文从**代码结构**的角度,按 `accelerator/pkg/manifest` 的子包逐个说明它是怎么实现的。

> **与 [`manifest-data-flow.md`](manifest-data-flow.md) 的分工**
> - 那篇讲"**数据怎么流动**":从制作 Manifest 模板的指令,到 flatten → ingest → fetch 的完整链路与关键代码。
> - 本文讲"**代码长什么样**":包布局、每个子包的职责、Manifest 的二进制形态、引用格式、存储后端、CLI,以及容易记混的点。
> - 两者互为参照;需要"端到端叙事"时看那篇,需要"按模块查"时看本篇。
>
> 权威定义仍在组件仓库文档:`accelerator/docs/manifest.md`、`store.md`、`cache.md`、
> `guest-runtime/docs/flatten.md`、`orchestrator/docs/node-build.md`。

---

我已经把源码从格式、写入、读取、加密、存储布局、CLI 全部看过。下面基于**代码实际实现**讲 accelerator 里的 manifest。

## 一、总体定位

`pkg/manifest` 是 accelerator 的**内容寻址数据层核心**,约 **9300 行**。它把任意"镜像/快照/文件"拆成分块、加密、存进 store,再用一个 **Manifest**(紧凑二进制对象)记录"这块数据由哪些块组成、怎么解密"。

代码组织是**分层子包**,`pkg/manifest` 本身只是门面(不写逻辑):

```
pkg/manifest/
├── config.go       门面:Config(YAML)+ NewIngester/NewFetcher 工厂
├── alias.go        对外类型别名(manifest.Manifest = codec.Manifest 等)
├── ref.go          引用解析:manifest://  file://  @digest/@hmac/@manifest/@location
├── codec/          二进制格式:Marshal / Unmarshal / AAD / UnsealKeys
├── chunker/        FastCDC 与固定分块
├── crypto/         收敛加密(chunk)+ 客户密钥封装(key table)+ tarstream 加密
├── ingest/         写管线:Source → 分块 → 加密 → Store.Put → 生成 Manifest
├── fetch/          读管线:Manifest + Cache → 解密字节(含分层 overlay)
└── bundle/         多 Manifest 打包载体(.bundle)
```

`pkg/manifest` 的包注释明确写了分工:

> codec — 磁盘二进制格式;chunker — FastCDC/固定分块;crypto — 收敛加密 + 客户密钥封装 key table;ingest — 写管线;fetch — 读管线

---

## 二、Manifest 对象本身是什么

### 1) 物理信封(存在 store 里的字节)

`codec/manifest.go` 定义:

```
[4 字节 "MANI"][1 字节 encoding][payload]
```

- `encoding = 0x00` → payload 原样 RAW
- `encoding = 0x01` → payload 是 **Go Snappy 块**编码
- 选择规则固定(不是配置):`saved ≥ 4 KiB 且 encoded*4 ≤ raw*3`
- 整个逻辑 Manifest(含 magic)硬上限 **64 MiB**

### 2) 逻辑布局

```
[Header 64B]
[ChunkEntry × N, 每条 56B]
[hole 区间 × M, 每条 16B]
[SealedKeyTable 可变长]
```

**Header(64B)** 含:`magic[4]`、`version`、`chunk_mode`、`image_size u64`、`chunk_count u32`、配置的 `chunk_min/max`、key table 的 offset/len、hole 数量与 hole table offset。

**ChunkEntry(每条 56B)**:`image_offset u64`、`plain_len u32`、`flags u32`、`cipher_hash[32]`、`8B 保留零`。按 offset 排序。

**关键不变量**(`codec` 里 `ErrBadGeometry` 校验):
> **Entries(数据)与 Holes 恰好无缝、无重叠地铺满 `[0, ImageSize)`。**

这里有个重要的语义区分,代码注释讲得很清楚:

- **Hole(洞)**:外部声明的"这里没有数据"(文件系统稀疏洞、qcow2 未分配区、TRIM 区间)。**永远不来自块内容**。读时由 fetch 层零填充,或在 overlay 时**向下层落穿**。
- **Zero chunk(全零块)**:`flags` 的 bit0。是**真实数据(零字节)**。**不加密、不存 store、key table 里也没有它**,读时本地合成零字节。它是**不透明的**,不会落穿到下层。

### 3) 封装的 key 表

`Keys [][32]byte` 是每个**非零块**的收敛密钥(明文形式,封存前)。存盘时用**客户密钥(ManifestKey)AES-GCM 封装**成 `SealedKeyTable`,AAD 绑定 Manifest 结构。

**这是关键安全点**:客户密钥**只封装 key 表**,它**不派生**块加密密钥(见下)。

---

## 三、写入管线(ingest)

`ingest/ingest.go` 的包注释直接给了流水线:

```
sparse.Source → Chunk → Encrypt → Store.Put(去重) → Marshal Manifest → Store.Put(manifest 分区)
```

细节(全部来自代码):

1. **输入是 `sparse.Source`**:Hole 段**不读也不分块**,直接变成 Manifest 的 hole 区间;Zero 段合成零字节喂给 chunker,**不调用 ReadAt**。数据**严格单向消费**,所以管道式源(稀疏文件流、tarstream)无需临时文件。
2. **一次 Ingest 只调一次 `AdmitWrite`**,拿到一次 `WriteAdmission`(含 generation + salt),该次 ingest 的所有块和最终 Manifest 都复用它。
3. **分块**:FastCDC(默认)或固定大小。
4. **每个块**:派生密钥 → 编码 → 加密 → `Put`,并记录一条 ChunkEntry + 它的 key。
5. **去重**:`Put` 返回 `isNew`;服务端已存在就跳过上传 body(内容寻址去重)。
6. **并发**:加密/上传用有界 worker 池;若 store writer 实现 `OrderedChunkStoreWriter`,则按逻辑序号有序追加(保证镜像顺序),再施加反压。
7. **收尾**:封 key 表 → 编码信封 → 在**同一 admission**下写入 manifest 分区。
8. 返回 `Result.ManifestKey` **就是最终 handle**;调用者**永远看不到**序列化后的 Manifest 字节。

---

## 四、加密模型:两把"钥匙",别混

### 1) 块加密 = 收敛加密(可去重)

`crypto/convergent.go`:

```go
// key = SHA256(salt || plaintext)
func DeriveKey(salt [32]byte, plaintext []byte) [32]byte
```

- 不变式:**同明文 + 同 salt → 同密文 → 同 ContentKey → 只存一份**
- 块物理对象格式(`ChunkFormat`):
  ```
  0x01 || AES-256-CTR(key, IV=0, plaintext)
  0x02 || AES-256-CTR(key, IV=0, snappy.Encode(plaintext))
  ```
- `ContentKey = SHA256(物理对象字节)`;Manifest 自身也是 `SHA256(物理信封)`

### 2) salt 与去重域

- **`server_salt`**:每次 ingest 从 store 的 `AdmitWrite()` 按 generation 取,opaque
- **`extra_salt`**(`--extra-salt`):混入进去,缩窄去重域(如按租户)。`ingest.mixSalt` 负责混合
- 逻辑是**域分离,不是授权**。同 salt 域内可去重,也意味着**可暴露"内容相等"**

### 3) 客户密钥(ManifestKey)

- `crypto/keytable.go` 的 `KeyTableEncryptor.Seal/Unseal`,**只封装 key 表**(`KeyTableFormatAESGCM = 0x01`)
- 丢失 → 该 Manifest 的 key 表**无法解封**
- 传递:`Config.ManifestSubConfig.Key`(hex)或 `$MANIFEST_KEY`,**环境变量优先且覆盖 YAML**(`CustomerKeyEnv`),这样密钥可不落在共享配置里;`CustomerKey()` 惰性解析,只在真正需要时才报错

代码注释还明确警告:**"客户密钥从不泄露"本身并不等于"存储内容不可推断"**——若有 salt 且能猜明文,就能推出候选块密钥去验证。所以安全边界要由部署方通过密钥/salt 访问控制来守。

---

## 五、读取管线(fetch)

`fetch/fetcher.go`:`Fetcher` 绑定 `cache.Getter`(内部指向 cache-ctl,或退化为 store-as-origin)与解密器。

- `OpenManifest(ctx, key)` → 拿 Manifest → 解析索引 → **解封 key 表**
- 默认 `Options{VerifyContent: true}`:解析前校验 `SHA256(物理 Manifest) == key`;首次读块时校验 `SHA256(物理块) == CipherHash`。而 `verify/import/export/repair` 路径**强制**开启校验
- 按需读:`RunAt` 只查稀疏表/索引(不读数据、不解密);真正 `ReadAt` 才并发取块
- 明文块缓存:key 含 `CiphertextHash` + 解密密钥 + 明文大小;有 32 项 / 32 MiB 上限、5 秒空闲过期

### 分层覆盖(`fetch/layered.go`)

```go
// top → bottom 叠加:最上层有数据者服务;
// 声明为 hole(或越界)→ 落穿下层;IsZero 块不透明,不落穿;Size 取各层最大
func NewLayered(layers ...Stream) Stream
```

这就是"**父层 + 实例增量**"的实现方式,也保留了嵌套 overlay 的 `ChunkRun` 能力。

---

## 六、引用格式(`ref.go`)

```
manifest://<恰好一个 64 位小写 hex>
file://<path>[@digest:<d>|@hmac:<d>|@manifest:<k>][@location:<name>]
```

- Manifest 引用**恰好一个内容 key**;不支持 `manifest://k1:k2`
- `file://` 的三种身份限定符**互斥**:`@digest`(明文载体身份)、`@hmac`(带密钥的外部身份)、`@manifest`(从多 Manifest 的 Bundle 里选根)
- `@location` 是**逻辑名**(非主机目录),规则 `[A-Za-z0-9][A-Za-z0-9._-]*`,允许首字符是数字以便直接用 UUIDv7 的沙箱/构建 ID
- 明确拒绝 `@sha256`(有测试)

---

## 七、存储后端(`pkg/store`)

Manifest 机制依赖 store 提供三类**内容寻址分区**与代际:

```go
type Partition string
const (PartitionChunk = "chunk"; PartitionManifest = "manifest"; PartitionBlob = "blob")
type ContentKey [32]byte
type WriteAdmission struct { Generation Generation; Salt [32]byte }
```

- `SaltForGeneration(g)` 是**唯一**的 salt 派生入口,保证在线准入与离线写入落在同一 salt 域(域字符串 `accelerator-salt-v1`)
- FS 后端的物理路径(`fs.go` `objectPath`):
  ```
  <root>/<partition>/<generation>/<hex前2>/<hex第3-4>/<完整hex>
  ```
- 后端支持 FS 与 S3 兼容;`PartitionBlob` 与 chunk/manifest 处理完全相同,仅做逻辑隔离

---

## 八、CLI(`manifest-ctl`)

`cmd/manifest-ctl/` 子命令(与文档一致):

| 命令 | 作用 |
|---|---|
| `store` | ingest → 上传 Manifest → stdout 输出 hex content key |
| `load` | 按 key 读出逻辑数据(可分层、可窗口、可 tail 操作) |
| `get-manifest` | 取回原始 Manifest 字节(调试) |
| `info` | 打印 Manifest 元数据(**不解 key 表**,故本地/stdin 无需客户密钥) |
| `verify` | 逐块取回解密,全量校验(**强制 SHA**) |
| `diff` | 比较两个本地 Manifest 的块重叠(去重率) |
| `config show/generate` | 打印/生成配置模板 |

配置加载规则:文件名只来自 `--manifest-config` 或 `$MANIFEST_CONFIG`(**无自动发现**);客户密钥 `$MANIFEST_KEY` 优先于 YAML。

---

## 九、几个容易记混的点(代码已明确)

| 概念 | 代码依据 | 要点 |
|---|---|---|
| Hole vs Zero | `codec` 的 `Holes` 注释 | Hole=外部声明的缺失,**读时落穿**;Zero=真实零数据,**不透明** |
| 两把钥匙 | `convergent.go` vs `keytable.go` | 块密钥=SHA256(salt‖明文);ManifestKey 只封 key 表 |
| 去重 vs 安全 | `crypto/config.go` 警告 | 去重域≠ACL;同 salt 域会暴露"内容相等" |
| 单次准入 | `ingest` 注释 | 一次 Ingest 一次 `AdmitWrite`,全部对象共用同一 generation+salt |
| 硬上限 | `codec` 常量 | 逻辑 Manifest ≤ 64 MiB;单逻辑块 ≤ `MaxChunkDecodedSize` |
| 版本 | `codec` | 当前 Version1;旧 `[MANI][Version1]` 布局 reader **拒绝** |

---

## 十、对照官方文档

权威文档在仓库内 `accelerator/docs/manifest.md`(631 行,我前面给你讲过)。代码与文档一致,区别只是代码里有更多实现细节(worker 池、有序写、scratch 预算、Stream 缓存上限等)。

需要我继续的话,可以:
1. 带你**逐行读**某个子包(比如 `codec.Marshal` 的字节级编解码,或 `fetch.Stream.ReadAt` 的并发/缓存逻辑);
2. 在 accelerator 里跑一遍 `manifest-ctl store/load/info/verify/diff` 的**离线 store↔load 往返**(文档 §7 有配方),让你亲眼看到 `manifest://` 生成与校验;
3. 画一张 Manifest 从 `Template.build` 到 `manifest://` 引用再到 `Sandbox.create` 还原的端到端数据流图。