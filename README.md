# VPhoneGaGa 3.4.0 底层架构实证报告

| 项目 | 内容 |
|---|---|
| 报告版本 | **v1.1**（确定性分层修订版） |
| 配套文档 | [`ARCHITECTURE.md`](ARCHITECTURE.md) —— 架构全解 · 启动流程实测 · 开源复现难度评估 |
| 分析对象 | `com.vphonegaga.titan` **3.4.0**（versionCode 3688） |
| 分析方法 | 纯系统行为取证（无反汇编、无反编译、未使用 IDA / Ghidra / Frida） |
| 验证载体 | 2 台宿主设备 + 1 个客户机实例的内部 shell |
| 权限层级 | 宿主 adbd（无 root）· 宿主 root（仅对照机）· 客户机内部 shell |
| **AI 辅助** | **pi.dev（deepseek-v4-flash）** |
| 证据分档 | 全文按 **A / B / C / U** 标注，并标注取得所需的**权限层级 P0/P1/P2** |
| **确定性层级** | **K1** 直接证明 / **K2** 行为高度支持的架构解释 / **K3** 黑盒不可区分 |

[english](./README_EN.md)

---

## 0. 摘要

本报告通过**无 root 的运行态观测**与**客户机内部 shell** 的双向取证，还原了商业安卓虚拟机 VPhoneGaGa 3.4.0 的可观测架构。

本版报告的方法论底线是：

> **外部可观测行为能够约束内部架构，但通常不能唯一确定内部实现。**

因此，全文把结论拆为三层：

| 层级 | 含义 | 允许的表述 |
|---|---|---|
| **K1 · 直接证明** | 可由实测输出直接证明的语义事实 | “观测到 / 可复现 / 直接证明” |
| **K2 · 行为高度支持** | 与观测高度吻合的候选架构模型 | “现有证据最支持 / 行为高度吻合 / 候选模型” |
| **K3 · 黑盒不可区分** | 外部黑盒实验无法唯一判定的内部实现 | “无法区分 / 不能唯一确定 / 仍为候选” |

核心发现六条：

1. **现有观测能够证明：VPhoneGaGa 在宿主 Android 环境中构造出了一个具有独立 Android 用户空间、进程语义、系统信息视图、存储体系及设备接口的运行环境。** 但黑盒实验无法据此唯一确定其内部各子系统究竟是直接复用宿主内核能力、通过用户态代理实现，还是采用自有实现后再与宿主系统对接。**K1 + K3。**
2. **系统调用投影层真实存在，但不是“接管 SVC 陷入指令”，而是自装的第二层 seccomp 过滤器。** `/proc/<pid>/status` 的 `Seccomp_filters` 字段给出分层证据：宿主应用进程为 1 层，客户机全部 85 个进程为 2 层。**K1。**
3. **`/proc` 被整体投影/伪造。** 拿到客户机内部 shell 后，可以对**同一个进程**同时读宿主侧与客户机侧，得到两套互相矛盾的自我描述：客户机自称 `uid=0` / 全 capability / `Seccomp: 0` / 内核 4.14.42 / Cortex-A53 / 4 GB RAM；宿主内核显示 `uid=10383` / `CapEff=0` / `Seccomp: 2` / 内核 5.15.167 / 骁龙 8 Gen 2 / 14.8 GB RAM。**K1。**
4. **客户机的 root 是运行在 app uid 内的 Magisk 26.0 体系。** 宿主设备**没有可用 root**（连 `su` 都不存在），客户机的 `magiskd / lspd / zygiskd64 / zygiskd32` 在宿主侧的**真实父进程全部是虚拟内核**；客户机被显示的父进程则是重建过的逻辑树。**K1 观测事实 + K3 成因机制。**
5. **它的可观测定位更接近「系统调用投影与设备仿真层」，而不是已证实的「用户态内核重实现」。** 请求处理在外部行为上分为三类**语义路径**：**B 合成/投影**、**C 重定向/虚拟文件系统**、**A 宿主能力复用/透传语义表现**。三类路径描述的是**可观测处理结果**，不宣称为内部确定存在的三个实现分支。**K2 + K3。**
6. **本报告不把任何内部实现路径视为已经证实。** 对网络、文件系统、系统调用处理等部分，本报告仅根据可观测行为建立候选架构模型。**网络维度不在本报告结论范围内。**

一句话概括：

> 从外部行为看，它像是在“演一个内核”；但内部究竟是“租用宿主内核能力”“自建用户态抽象后再对接宿主”，还是两者混合，黑盒实验无法唯一确定。**能确定的是它维持了高度一致的 Android 语义；不能确定的是这些语义在哪一层被实现。**

**本报告的范围限定**：仅分析进程、调度、系统调用可观测行为、文件系统、存储格式与 `/proc` 投影。**不涉及网络架构**——本报告不就客户机的网络实现作任何结论。

---

## 1. 方法、权限分级与合规声明

### 1.1 AI 辅助声明

| 项目 | 说明 |
|---|---|
| AI 接口 | **pi.dev** |
| 模型 | **deepseek-v4-flash** |
| 参与范围 | 观测方案设计、命令编排、原始输出整理、交叉印证、结论梳理、报告撰写与中英文本地化 |
| 未参与部分 | 所有命令均在真实设备上实际执行；所有输出均为真实终端回显，未由 AI 生成或推测 |

**必须声明的风险**：AI 辅助分析会产生错误判断。本报告 §6「结论更正表」中列出的误判均由本报告的 AI 辅助分析产生，并经后续实测复核后更正。

列出这些条目的目的不是免责，而是提示读者：**本报告的可信度来自 §8 的可复现命令，以及本版新增的 §0 确定性分层，而非来自任何一方的权威。**

### 1.2 权限分级（本报告全文使用）

| 层级 | 代号 | 身份 | 取得方式 | 使用范围 |
|---|---|---|---|---|
| 宿主 adbd（**无 root**） | **P0** | `uid=2000(shell)`，`context=u:r:shell:s0` | `adb shell` | 主载体与对照载体**均**可用 |
| 宿主 root | **P1** | `uid=0(root)` | `su -c`（**仅对照载体设备 B 可用**，Magisk Alpha） | 仅对照载体 |
| 客户机内部 shell | **P2** | 客户机内 `uid=2000` → `su` → 客户机 `uid=0` | `adb connect 127.0.0.1:6556` | 仅主载体的客户机实例 |

> **重要**：主载体设备 A **没有 P1 层级**（无 `su`、无 magiskd）。因此所有需要 P1 的观测**只在对照设备 B 上取得**，报告中对每条此类结论均会注明。

### 1.3 P0 / P1 / P2 的实际权限边界（实测）

| 观测对象 | P0（无 root） | P1（root） | P2（客户机内） |
|---|---|---|---|
| `ps -A -o PID,PPID,USER,NAME` | ✅ | ✅ | ✅ |
| `/proc/<pid>/status`（Name/PPid/Uid/Gid/CapEff/CapPrm/Seccomp/Seccomp_filters/NoNewPrivs/TracerPid/NSpid） | ✅ | ✅ | ✅ |
| `/proc/<pid>/cgroup` | ✅ | ✅ | ✅ |
| `/proc/<pid>/oom_score_adj` | ✅ | ✅ | ✅ |
| `/proc/<pid>/cmdline` | ✅ | ✅ | ✅ |
| `/proc/net/unix`（套接字名称枚举） | ✅ | ✅ | ✅ |
| `dumpsys` / `pm` / `getprop` | ✅ | ✅ | ✅ |
| **`readlink /proc/<pid>/exe`** | ❌ | ✅ | ✅ |
| **`/proc/<pid>/ns/`（命名空间）** | ❌ DENIED | ✅ | ✅ |
| **`/proc/<pid>/maps`（内存映射）** | ❌ DENIED | ✅ | ✅ |
| **`/proc/<pid>/fd/`（文件描述符）** | ❌ DENIED | ✅ | ✅ |
| **`/proc/<pid>/environ`** | ❌ DENIED | ✅ | ✅ |
| **`/data/data/<pkg>/`（私有数据目录、容器文件）** | ❌ DENIED | ✅ | — |
| **`/data/app/*/<pkg>*/lib/arm64/`（APK 原生库，`[REDACTED]`/`strings` 的对象）** | ❌ DENIED | ✅ | — |
| **宿主侧 `/proc/version`、`/proc/cpuinfo`、`/proc/meminfo`** | ✅ | ✅ | — |

### 1.4 使用的手段

| 类别 | 具体手段 | 层级 |
|---|---|---|
| 进程与调度 | `ps`、`/proc/<pid>/{status,cgroup,oom_score_adj,cmdline}` | P0 |
| 内核状态字段 | `Seccomp` / `Seccomp_filters` / `CapEff` / `NoNewPrivs` / `TracerPid` / `NSpid` | P0 |
| IPC 名称枚举 | `/proc/net/unix` | P0 |
| APK 组件元数据 | `[REDACTED] -lW / -dW / --[REDACTED]`、`strings`、`od` | P1 |
| 存储容器格式 | 文件头十六进制读取（`od`）、魔数比对、镜像头字段解码 | P1 |
| 内存与描述符 | `/proc/<pid>/{maps,fd,ns}` | P1 |
| 客户机内部视角 | 客户机自带 adbd（`127.0.0.1:6556`）的 shell + `su` | P2 |

### 1.5 未使用的手段

未反汇编任何 SO/DEX；未反编译；未使用 IDA / Ghidra / Frida / Xposed；未解析 `readonly.bin` 内部的 ELF 指令；未尝试提取、解密或重打包任何镜像；**未做任何网络抓包、路由或流量分析。**

### 1.6 合规

- 全部观测在**自有设备、自有授权副本**上进行。
- 报告只描述**“观测到了什么”**，不描述**“如何绕过 / 改写 / 提取”**。
- 报告**不包含**任何可用于规避产品保护措施的步骤、密钥或偏移表。
- 属**架构分析与互操作性研究**，不构成破解。

### 1.7 证据分档与确定性层级

| 档位 | 含义 |
|---|---|
| **A** | 无 root 即可复现（**P0 可达**） |
| **B** | 需 root（**P1 可达**） |
| **C** | 需客户机内部 shell（**P2 可达**） |
| **U** | **未定论**（现有手段无法判定） |

| 确定性层级 | 含义 |
|---|---|
| **K1** | 直接证明：可由实测输出直接证明的语义事实 |
| **K2** | 行为高度支持：与观测高度吻合的候选架构模型，但非唯一实现 |
| **K3** | 黑盒不可区分：外部行为无法唯一判定的内部实现路径 |

> **原则**：越靠近“内部机制”的结论，确定性越低。报告中所有“复用宿主内核”“用户态代理”“自有实现”等表述，除非明确标为 K1，否则一律视为 K2 或 K3。

---

## 2. 验证设备与环境

### 2.1 设备 A —— 主载体（用于验证“无需宿主 Root”）

| 项目 | 实测值 | 层级 |
|---|---|---|
| 品牌 / 型号 | OnePlus / **PJE110** | P0 |
| 平台 | 高通 **SM8550**（Snapdragon 8 Gen 2，内部代号 `KALAMA`） | P0 |
| CPU | 8 核：3×`0xd46`(Cortex-A510) / 2×`0xd47`(A715) / 2×`0xd4d`(A710) / 1×`0xd4e`(X3) | P0 |
| 内存 | 15,496,684 kB ≈ **14.8 GiB** | P0 |
| 存储 | 933 GB（已用 403 GB） | P0 |
| 系统 | **ColorOS/OxygenOS 15.0.0.870(CN01)**，Android **15** / SDK **35** | P0 |
| 构建指纹 | `OnePlus/PJE110/OP5CF9L1:15/TP1A.220905.001/U.1d94395_275952_27eb03:user/release-keys` | P0 |
| 构建日期 | 2025-09-26 | P0 |
| 内核 | `5.15.167-android13-8-o-01144-gdc8278c1c5f9` | P0 |
| 完整性 | `ro.build.flavor=qssi-user`、`type=user`、`tags=release-keys`、bootloader **锁定**、`verifiedbootstate=green` | P0 |
| **Root 状态** | **无可用 root**：`command -v su` 失败、`/system/bin/su` 不存在、无 magiskd、无 root 进程 | P0 |
| 遗留痕迹 | 装过 **KernelSU 管理器 v3.3.0**；`/data/adb` 存在但不可读 ⇒ **不是“从未 root 过”的设备** | P0 |

> **这是本报告的主载体。** 其价值在于：客户机的 Magisk / LSPosed / Zygisk 是在**宿主没有任何可用 root 通道**的前提下出现的。同时它**不提供 P1 层级**，因此一切需要 root 的观测都必须依赖设备 B。

### 2.2 设备 B —— 对照载体（唯一提供 P1 层级的设备）

| 项目 | 实测值 | 层级 |
|---|---|---|
| 品牌 / 型号 | Redmi / **Redmi K30 5G**（`picasso`） | P0 |
| 平台 | 高通 **SM7250**（Snapdragon 765G） | P0 |
| CPU | 8 核：2×`0x804`(Cortex-A76) / 6×`0x805`(Cortex-A55) | P0 |
| 内存 | 7,661,616 kB ≈ **7.3 GiB** | P0 |
| 系统 | **LineageOS 22.2 UNOFFICIAL**（Android **15** / SDK **35**） | P0 |
| 构建 | `lineage_picasso-userdebug 15 BP1A.250505.005 eng.cnmrli test-keys` | P0 |
| 构建日期 | 2025-09-28（**非官方构建，编译者字段为个人名**） | P0 |
| 内核 | `4.19.314-Hanabi-2.2-g6e7223ac503a-dirty` | P0 |
| **Root 状态** | **Magisk Alpha 正在运行**：包 `io.github.vvb2060.magisk` v`c3db2e36-alpha`；`magiskd`(uid 0) 存活；另挂 Zygisk 模块 `playintegrityfix` | P0 观测 / **P1 来源** |
| 属性可靠性 | **不可靠**：`ro.build.tags=release-keys` 与 display.id 中的 `test-keys` 矛盾；`type=user` 与 flavor 的 `userdebug` 矛盾；`verifiedbootstate=green`+`flash.locked=1` 与“已解锁且已 root”矛盾 ⇒ **Magisk 属性重置在生效** | P0 |

> **该设备不可用于验证“无需宿主 Root”**，仅提供 P1 层级并作为对照组。其 `getprop` 输出不可信，基于属性的结论一律不采信。

### 2.3 客户机实例 —— 运行在设备 A 内（P2 层级来源）

通过客户机自带 adbd 取得内部 shell（`adb connect 127.0.0.1:6556`）：ADB 广播身份为 `product:cancro model:Nexus device:android`。

| 项目 | 客户机自我描述 | 宿主内核实际情况 | 层级 |
|---|---|---|---|
| 系统版本 | Android **10** / SDK **29** | 宿主 Android 15 / SDK 35 | P2 / P0 |
| 构建指纹 | `samsung/cancro/android:10/KOT49H/eng.build.20220315.203416:user/release-keys` | `OnePlus/PJE110/…:15/…` | P2 / P0 |
| `ro.build.id` | `KOT49H`（**Android 4.4 的 build id**，故意错配） | — | P2 |
| 机型 | `model=Nexus`, `brand=samsung`, `device=android`, `name=cancro` | PJE110 / OnePlus | P2 / P0 |
| 构建日期 | 2022-03-15 20:31:13 PDT | 2025-09-26 | P2 |
| 安全补丁 | 2019-09-05 | — | P2 |
| 内核 | `4.14.42-titan (titan@ubuntu) gcc 4.8.4 #34 SMP PREEMPT 2019-11-09` | `5.15.167-android13-8-…` | P2 / P0 |
| CPU | Cortex-A53 (`0x801`) × 8 | 骁龙 8 Gen 2（`0xd46/0xd47/0xd4d/0xd4e`） | P2 / P0 |
| 内存 | 4,063,232 kB ≈ **3.9 GB** | 15,496,684 kB ≈ **14.8 GB** | P2 / P0 |
| `/data` 容量 | 933 GB | 933 GB（**未伪装，泄漏**） | P2 |
| Root | **Magisk 26.0**（`26.0:MAGISK:R` / `26000`） | uid 10383 / CapEff 0 | P2 / P0 |
| 应用数 | 141 个已装包（无 GApps） | — | P2 |
| 系统二进制 | `/system/bin` 379 个 | — | P2 |
| 序列号 | `[REDACTED]`（硬编码） | — | P2 |

> ⚠️ **该客户机实例非出厂状态**：`/data/adb/start.sh` 属主为 `u0_a100`、存在 1.7 MB 的 `su_arm64`、`/data/adb/modules/zygisk_lsposed`。引用“客户机自带 LSPosed”时必须声明这是实例内的后装模块。

### 2.4 环境干扰项（必须声明）

| 干扰项 | 影响 | 处置 |
|---|---|---|
| **KernelSU 管理器 + `/data/adb`**（设备 A） | 说明设备曾被尝试 root | 已声明；但**当前无可用 root 通道** |
| **Magisk Alpha + Zygisk 模块**（设备 B） | 属性被重置，root 模块可任意改 cgroup | 该机降级为对照；其 cgroup 数据与设备 A 矛盾，以设备 A 为准 |
| **客户机内后装 LSPosed 模块** | 客户机非纯净实例 | 已声明 |

---

## 3. 软件版本

| 项目 | 值 | 层级 |
|---|---|---|
| 包名 | `com.vphonegaga.titan` | P0 |
| **版本名** | **3.4.0** | P0 |
| 版本号 | **3688** | P0 |
| minSdkVersion | **21** | P0 |
| **targetSdkVersion** | **29**（Android 10） | P0 |
| 实例目录 | `files/instance1/androidfs_10.0.0/` | P1 |
| 设备 A / B 版本 | **完全一致**（3.4.0 / 3688） | P0 |

> **`targetSdk=29` 是当前实现路线的重要兼容条件之一**：把 targetSdk 停在 Android 10，可显著降低 Android 11+ 分区存储、包可见性、后台执行与进程数限制带来的摩擦，也显著降低了在应用沙箱内承载完整 Android 10 用户空间时的框架约束。
>
> ⚠️ **但“它是架构成立的必要条件”尚未通过对照实验验证**（未测试 targetSdk=30/31 下的行为）。本条标 **U 级 / K3**。

**客户机镜像**：Android 10 系统，2022-03-15 编译（`eng.build.20220315.203416`），安全补丁级别 2019-09-05（对应一次真实的 Android Q 构建）。【P2】

---

## 4. 观测结果

> 每条观测均标注 **证据档位** 与 **所需权限层级**。涉及内部机制的判读另标 **K1 / K2 / K3**。

### 4.1 进程拓扑 —— **A 级 / P0 / K1**

宿主 zygote64（设备 A 为 PID 1436）下：

```text
宿主 zygote64
├── com.vphonegaga.titan              uid 10383   cpuset:/foreground
└── com.vphonegaga.titan:instance1    uid 10383   cpuset:/top-app
    └── titan64_0:kernel              ← 客户机虚拟内核（64 位）
        ├── titan32_0:kernel          ← 客户机虚拟内核（32 位）
        ├── titan64_1:init            ← 客户机 init
        │   ├── titan64_59:netd / 60:zygote64 / 105:surfaceflinger
        │   ├── titan64_107:adbd      ← 客户机自带完整 adbd
        │   ├── titan64_164:su
        │   └── titan64_249:system_server
        ├── titan64_43:magiskd        ← 父进程 = 虚拟内核，**不是 init**
        ├── titan64_56:lspd           ← LSPosed daemon，父 = 虚拟内核
        ├── titan64_259:zygiskd64     ← 父 = 虚拟内核
        └── titan32_506:zygiskd32     ← 父 = **32 位**虚拟内核
```

**规模**：客户机进程 **85 个**（快照值；对照设备 B 为 87）。客户机内可见 100 个 PID 目录。【P0/P2】

**命名规则**：`titan{32,64}_<客户机虚拟PID>:<客户机进程名>`。该虚拟 PID 与客户机内 `ps` 完全对应（见 §5.2）。【P0 + P2 交叉验证】

**修正一处拓扑错误**：`com.vphonegaga.titan` 与 `:instance1` 的 PPid **相同**（都指向宿主 zygote），二者是**宿主 zygote 的兄弟进程**，不是父子。虚拟内核的父进程是 `:instance1`。

### 4.2 权限与调度 —— **A 级 / P0 / K1 观测 + K2 机制解释**

| 观测项 | 值 |
|---|---|
| 客户机全部进程 uid | **10383**（app uid，无例外） |
| 客户机全部进程 `CapEff` / `CapPrm` | `0000000000000000` |
| 客户机全部进程 `NoNewPrivs` | `1` |
| 客户机全部进程 `TracerPid` | **0**（⇒ **排除 ptrace 拦截路线**） |
| 客户机全部进程 `Seccomp` | `2` |
| 客户机全部进程 **`Seccomp_filters`** | **`2`** ← 见 §4.3 |
| 命名空间 | `/proc/<pid>/ns/` 仅 `cgroup` / `mnt` / `net`；**无 `NSpid` 字段** ⇒ **无 PID namespace**，且无 UTS / IPC / USER / TIME【P1】 |
| 挂载 | 客户机进程 `mountinfo` 与宿主 App 完全一致（152 条）；**无任何产品专属挂载点** ⇒ 外部未观测到“虚拟分区”以挂载形式出现【P1】 |
| cgroup | 客户机整树位于 `cpuset:/top-app`，其父 `instance1` 位于 `/foreground` |
| `oom_score_adj` | 客户机整树 `0`，`instance1` 为 `101` |

### 4.3 ★ 第二层 seccomp 过滤器 —— **A 级 / P0 / K1（核心证据）**

`/proc/<pid>/status` 的 `Seccomp_filters` 字段给出不可辩驳的分层证据：

| 进程 | `Seccomp` | **`Seccomp_filters`** |
|---|---|---|
| 宿主 `init` / `zygote64` / `netd` | 0 | 0 |
| 宿主 `systemui` | 2 | **1** |
| `com.vphonegaga.titan` | 2 | **1** |
| `com.vphonegaga.titan:instance1` | 2 | **1** |
| **`titan64_0:kernel`** | 2 | **2** ← 跃迁点 |
| **客户机全部 85 个进程** | 2 | **2**（100%） |

**判读**：

- Android 对每个应用进程强制安装 1 层 seccomp 过滤器（由 zygote 安装），故宿主侧恒为 1 层。
- seccomp 过滤器**只可叠加、不可移除**。层数由 1→2 的跃迁发生在 `instance1` fork 出虚拟内核之后、客户机代码运行之前。
- 因此**现有证据最支持“第 2 层由客户机虚拟内核在自举阶段安装，并由其后代继承”这一解释**；但**具体安装调用者尚未被直接观测**。理论上仍不能完全排除其他路径（例如 `instance1` 在极短窗口内安装、某个 loader/初始化组件安装、或某个尚未定位的初始化线程完成安装），只是它们与整体架构的吻合度远低于前者。**K2。**
- 交叉印证（P1）：`libuserkernel64.so` 字符串表含 `PR_SET_SECCOMP` / `PR_GET_SECCOMP` / `PTRACE_SEIZE` / `PTRACE_GETREGS` 等常量。
- 宿主设备 A **无 root、无 Magisk、无 Zygisk**，该层不可能来自宿主。

⇒ **VPhoneGaGa 的用户态系统调用投影确实存在，实现层为 seccomp。**（具体策略 `RET_USER_NOTIF` / `RET_TRACE` / `RET_ERRNO` 需读 BPF 程序 —— **U 级 / K3**。）

### 4.4 ★ `/proc` 整体投影/伪造 —— **C 级 / P2 对照 P0 / K1**

取得客户机内部 shell 后，可对**同一个进程**同时读两侧视角：

| 观测项 | 客户机视角 (P2) | 宿主内核真相 (P0) | 判定 |
|---|---|---|---|
| `su -c id` | `uid=0(root) gid=0(root)` | uid **10383** | **投影/伪造** |
| `CapEff` / `CapPrm` | `0000003fffffffff`（全 capability） | `0000000000000000` | **投影/伪造** |
| `Seccomp` | **0** | **2**（且 2 层过滤器） | **投影/伪造** |
| `NoNewPrivs` | **0** | **1** | **投影/伪造** |
| PID 空间 | `init=1`, `magiskd=43`, `zygote64=60`, `system_server=249` | 7098 / 7227 / 7263 / 7957 | **虚拟 PID 映射** |
| `/proc` 数字目录数 | 100（最大 PID 2554） | 宿主 300+ | **过滤** |
| 可见宿主真实 PID | **否**（6341 / 6839 / 7024 / 7263 全部不可见） | — | **过滤** |
| `/proc/version` | `4.14.42-titan (titan@ubuntu) gcc 4.8.4 …2019` | `5.15.167-android13-8-o-01144` | **投影/伪造** |
| `/proc/cpuinfo` | `CPU part: 0x801`（Cortex-A53）× 8 | `0xd46/0xd47/0xd4d/0xd4e` | **投影/伪造** |
| `/proc/meminfo` | `4,063,232 kB` | `15,496,684 kB` | **投影/伪造** |
| `/proc/uptime` | `386296188` 秒（**≈ 12.2 年**，且 idle > uptime） | `621609.78` 秒 | **投影/伪造（露馅）** |
| `/proc/self/maps` | `/system/lib64/libnetd_client.so`，dev `03:08`，ino `3080` | `…/androidfs_10.0.0/system/readonly.bin`，dev `fd:26`，ino `118337` | **路径改写/展示层投影** |
| `/proc/self/fd` | `0/1/2 -> sock:[725]` | 真实 socket | **投影/伪造（格式错误）** |
| `/proc/1/exe` 权限位 | `lr--r--r--` | 真 procfs 恒为 `lrwxrwxrwx` | **投影/伪造痕迹** |
| `cgroup` | `2:cpu:/apps` / `1:cpuacct:/`（Android 10 布局） | 6 控制器 + `/uid_10383/pid_6839` | **投影/伪造** |
| `/proc/mounts` | `/dev/block/platform/host/by-name/system` ext4 | 无对应挂载 | **投影/伪造** |
| `df /data` | 933 GB | 933 GB | **泄漏（未伪装）** |
| SELinux 上下文 | `--  u:object_r:toolbox_exec:s0`（多余 `--`） | — | **仿真瑕疵** |

**关键洞察**：过滤器把 `Seccomp` 投影成 `0` —— **它一边拦截/投影该进程的系统调用，一边告诉这个进程“我不存在”。**

> 注意：这里能直接证明的是“同一进程在客户机视角与宿主视角下得到不同语义结果”。至于该结果由“路径级 hook + 合成”“用户态 VFS”“seccomp 用户态通知”还是混合机制产生，属 **K3**。

### 4.5 ★ 投影的自证式破绽 —— **C 级 / P2 / K1（最有力证据）**

**同一内核状态，三个接口两个答案：**

```text
$ cat /proc/self/mountinfo
28 26 3:8 / / ro,seclabel,barrier=1 shared:2 - ext4 /dev/block/platform/host/by-name/system rw,seclabel

$ cat /proc/mounts
/dev/block/platform/host/by-name/system / ext4 ro,seclabel,barrier=1 0 0

$ mount
/dev/block/mtdblock0 on / type ext4 (ro,seclabel,barrier=1)
                    ↑↑↑↑↑↑↑↑↑↑ 完全不同的设备名
```

同类破绽：

| # | 破绽 | 说明 |
|---|---|---|
| 1 | `/proc/mounts` 与 `mount` 给出不同设备名 | 同一状态两个答案 ⇒ **与接口/路径级投影模型高度吻合**（K2，非直接证明内部实现） |
| 2 | `/proc/uptime` = 386,296,188 秒（**12.2 年**），且 idle 时间 > uptime | 结构体拼装错误 |
| 3 | `/proc/self/fd` 显示 `sock:[725]` | Linux 内核恒为 `socket:[inode]`；且 inode 号小得离谱 |
| 4 | `/proc/1/exe` 权限位 `lr--r--r--` | 真 procfs 的 `exe`/`cwd` 恒为 `lrwxrwxrwx` |
| 5 | 设备路径 `platform/**host**/by-name/system` | 真机平台名为 `1d84000.ufshc` 之类；**`host` 是产品自己的命名，自我暴露** |
| 6 | `/share` 挂载源写着宿主路径 `/storage/emulated/0/Android/data/com.vphonegaga.titan/files/instance1/shared` | **宿主路径泄漏** |
| 7 | `context=--  u:object_r:toolbox_exec:s0` | SELinux 仿真层拼装瑕疵 |

⇒ **用产品自身的 bug 证明它在投影/伪造，比任何外部推断都更有说服力。** 但“投影/伪造”本身是 K1；投影的具体内部实现仍是 K2/K3。

**实现模型（与观测高度吻合，但非直接证明）**：真实 procfs 仍是宿主内核的（否则 `/proc/version` 不会有内容），而**特定路径的 `openat` / `read` 被第 2 层 seccomp 过滤器截获/投影**，从内存返回**合成内容**。这是 **K2 候选模型**。

宿主侧 fd 表中存在数百个 `memfd:titan-tmp-inode-N (deleted)`【P1】，它只能证明**存在大量匿名/临时内存对象与用户态虚拟文件实现相关**。把“它们就是所有假 /proc 文件的实体”当作已证事实是**超出证据边界**的——更准确的表述是：该现象**与上述实现模型高度吻合**。**K2。**

至少被替换/投影的路径（P2 实测）：`/proc/<pid>/{status,cgroup,maps,fd/*,exe}`、`/proc/{mounts,self/mountinfo}`、`/proc/{cpuinfo,meminfo,uptime,version}`。

### 4.6 硬件代理总线 `@titan-pipe-*` —— **A 级 / P0 / K1 名称枚举**

`/proc/net/unix` 对 shell 身份完全可读，暴露了客户机子系统与宿主之间的 IPC 通道名称：

```text
@titan-pipe-1-framebuffer      @titan-pipe-1-input         @titan-pipe-1-activity
@titan-pipe-1-gsm              @titan-pipe-1-gps
@titan-pipe-1-camera  (+ name=camera0 / camera1)           @titan-pipe-1-sensors
@titan-pipe-1-fingerprint      @titan-pipe-1-crash         @titan-pipe-1-hw
@titan-pipe-1-ipc              @titan-pipe-1-network
@titan-process-worker-server-1-<PID>    × 86
```

**以上仅为 `/proc/net/unix` 的原始名称枚举。本报告不据此推论任何网络或通信架构。**

与宿主侧 `libuserkernel64.so` 字符串表中的 `titan-virtpipe-dma-%u-%d` / `titan-virtpipe-shm-%u-%d` / `titan-%u-process-monitor` **完全对应**。【P1】

⇒ **这组命名揭示了客户机外设存在代理通道**：相机 / GPS / 通信 / 传感器 / 指纹 / 图形 / 输入 / Activity 各自有独立的抽象 unix socket 通道。客户机内另可见产品自有属性 `android.host.adb.port=6556`、`android.host.adb.server.port=6038`。【P2】

### 4.7 存储层 —— **B 级 / P1 / K1 格式观测 + K2 实现解释**

宿主侧私有目录 `files/instance1/androidfs_10.0.0/`（合计 1.8 GB）：

```text
├── androidfs.bin          64 B     魔数 [REDACTED] / 裸字节 [REDACTED]
├── locales.bin           491 B
├── config.gz            1305 B
├── fscache.bin        402,698 B
├── system/
│   ├── readonly.bin   1,557,878,007 B   (1.45 GiB)  魔数 [REDACTED] / 裸字节 [REDACTED]
│   ├── superblock.bin  16 B            魔数 [REDACTED] / 裸字节 [REDACTED]
│   └── 00000000/       可写索引对象
├── vendor/  readonly.bin 30,533,337 B + superblock.bin 16 B
├── data/    831 个索引对象 + fscache.bin 67,108,864 B (64 MiB) + superblock.bin 16 B
├── cache/   superblock.bin 16 B + 00000000/ (14 项)
└── root/
    ├── block.img        8,388,608 B    ← 真正的 Android boot 镜像
    ├── readonly.bin     2,696,464 B
    └── superblock.bin          16 B
```

**文件头字段解码（可交叉验证）**：

```text
<分区>/superblock.bin (16 B)          <分区>/readonly.bin (头 64 B)
  +0x00  42 50 55 53  "[REDACTED]"            +0x00  41 54 49 54  "[REDACTED]"
  +0x04  10 00 00 00  = 16  ← 头长度     +0x04  40 00 00 00  = 64  ← 头长度
  +0x08  9d 11 00 00  = 4509 ← 对象数    +0x08  9d 11 00 00  = 4509 ← **与 superblock 完全相等**
         system=4509 vendor=503
         data=3800   cache=11  root=23
```

`readonly.bin` 头中的对象计数与同分区 `superblock.bin` **逐分区精确相等**（system 4509 / vendor 503），这是“[REDACTED] 为索引、[REDACTED] 为数据”分层关系最硬的交叉证据。

**魔数字节序（必须注明）**：三个魔数在磁盘上均为**每两个字符一组、按 16 位小端存储**，因此**裸字节序是 `[REDACTED]` / `[REDACTED]` / `[REDACTED]`**；`od -x` 会将其渲染为大端字符对 `[REDACTED]` / `[REDACTED]` / `[REDACTED]`。撰写与引用时必须写清这一点，否则任何用 `xxd` / `od -c` 复核的读者都会认为数据造假。

**`root/block.img` 是一个结构完全合法的 Android boot image（header v0）**：

```text
+0x00  41 4e 44 52 4f 49 44 21   "[REDACTED]"
+0x08  70 0e 03 00   kernel_size  = 200,304
+0x0C  00 80 00 10   kernel_addr  = [REDACTED]   （标准 ARM64）
+0x10  ec f0 28 00   ramdisk_size = 2,682,092
+0x14  00 00 00 11   ramdisk_addr = 0x11000000   （标准）
+0x20  00 01 00 10   tags_addr    = 0x10000100
+0x24  00 10 00 00   page_size    = 4096
+0x30  74 69 74 61 6e   name = "titan"
```

⇒ **“纯用户态模拟真机 Boot 分区结构”这一论断由推演升为实测。K1。**

**容器格式族谱**：APK 内 `libp7zip.so`（3.1 MB）字符串表含 `[REDACTED]` / `AES256CBC` / `[REDACTED]` / `BCJ2` / `Deflate64` / `PPMd`。⇒ [REDACTED]/[REDACTED]/[REDACTED] 并非从零设计的加密文件系统，而是 **7-Zip 家族之上的私有封装层**。**K2。**

**`readonly.bin` 未加密（推翻早期结论）**：客户机进程**直接 mmap 该文件**（客户机 init 166 处、SF 358 处映射），在映射偏移处直接读取文件得到 `7f 45 4c 46`（ELF 头）与合法 ARM64 指令。⇒ 它是**明文、页对齐、可直接 mmap 的扁平 ELF 容器**（设计思想接近 EROFS / incfs）。**K1 观测；内部是否还有额外映射层为 K3。**

**真正的 AES 用在哪**：产品自身日志 `AndroidLog.log`（223 KB）/ `UserKernel.log` / `UserKernelApi.log` **全部为高熵密文**。⇒ 加密能力真实存在，但施加对象是**自身运行日志**，而非客户机镜像。**K1。**

### 4.8 虚拟 Root —— **C 级 / P2 / K1 形态观测 + K2 机制解释**

客户机内实测：

```text
$ su -c id
uid=0(root) gid=0(root) groups=0(root) context=--  u:object_r:toolbox_exec:s0

$ magisk -v        →  26.0:MAGISK:R
$ magisk -V        →  26000
$ ls -l /sbin/magiskinit  →  -rwxr-x--- 1 root root 642952
$ ls -l /sbin/su          →  /sbin/su -> ./magisk

/data/adb/
├── lspd/  magisk/  magisk.db (40960 B)
├── modules/zygisk_lsposed/
├── post-fs-data.d/  service.d/
├── start.sh   (u0_a100, 100 B)
└── su_arm64   (1,708,512 B)
```

**结论**：

- 产品**没有重新实现一套 root 状态机**，而是运行 **Magisk 26.0 体系**。⚠️ **证据边界**：`magisk -v` 输出 `26.0:MAGISK:R` 只能证明“运行的是 Magisk 26.0 兼容实现/二进制形态”。**本报告未对二进制做官方构建的 hash 对照**，因此不能断言“未经修改的官方原版”。**K1 形态 / K3 来源。**
- 它能工作的外部原因是：第 2 层 seccomp 过滤器/投影层把 `getuid` / `getresuid` / `capget` 的返回值投影为 `0` / 全 capability。**宿主内核实测（P0）：同一进程 uid=10383、CapEff=0。**
- `zygisk_lsposed` 模块解释了 `zygiskd64` / `zygiskd32` / `lspd` 三个进程的来源。
- 宿主设备 A **无任何可用 root 通道**，故客户机 root 不可能是宿主提权的结果。

### 4.9 调度优先级 —— **A 级 / P0 / K1 观测 + K2 机制解释**

设备 A 上的受控实验（把 VM 切到后台再切回）：

```text
                    instance1       客户机全树(85)
HOME 之前     →  cpuset:/top-app     cpuset:/top-app    (100%)
HOME 之后     →  cpuset:/foreground  cpuset:/top-app    (100%，一个没掉)
oom_score_adj:   instance1 = 101     客户机全树 = 0
```

**`instance1` 被宿主从 `top-app` 降级到 `foreground`，客户机 85 个进程纹丝不动。**

⇒ **与观测高度吻合的机制解释（K2）**：客户机进程在 **VM 启动瞬间从 `instance1` fork 时继承了当时的 cgroup 桶与 `oom_score_adj`**（用户在前台点开虚拟机 → `instance1` 处于 `top-app` / `oom 0`），**此后宿主对 `instance1` 的任何降级都不会影响已 fork 的客户机进程**。

**准确表述（限定在本实验窗口内）**：「客户机进程在启动瞬间获得了**独立于 `instance1` 后续状态变化**的调度归属，并在本次前后台切换实验中保持 `top-app`」。

> ⚠️ **不能推出“永久”。** 本实验只覆盖了一次 HOME 切换后约 6 秒的窗口。进程死亡重启、LMKD 干预、Activity 生命周期变化、vendor 调度器、task profiles、cgroup freezer 等场景均**未覆盖**。本条标 **U 级 / K3**。

**未解决的跨设备矛盾（U 级 / K3）**：在设备 B 上做同样观测，客户机树**跟随** `instance1` 一起从 `top-app` 掉到 `foreground`。设备 B 是 Magisk Alpha root 机，root 模块可任意改 cgroup，故以设备 A 数据为准，但差异原因未定论。

### 4.10 图形栈 —— **B 级 / P1 / K1 映射观测 + K3 实现判定**

| 持有者 | `/dev/kgsl-3d0` | `/dev/ion` | `dmabuf` |
|---|---|---|---|
| 宿主 SurfaceFlinger | 12 fd，**840 处 mmap** | 2 | 70 |
| 客户机 SurfaceFlinger | 1 fd，**322 处 mmap** | 2 | 35 |

`kgsl / ion / dmabuf` 是 Android 图形栈对**任何** GPU 渲染进程的默认路径，且宿主 SF 的映射数**远多于**客户机 SF。外部观测到客户机 SF 持有宿主 `/dev/kgsl-3d0` 等路径；但内部究竟是完全直通、代理转发还是用户态中转，黑盒无法唯一确定。**K3。**

真正值得记录的是 §4.6 的 `@titan-pipe-*` 通道命名。

### 4.11 进程内 ELF 装载 —— **B 级 / P1 / K1 元数据观测**

- 客户机进程由 `exec` 宿主 App 目录下的 `libloader64.so` / `libloader32.so` 得到，`[REDACTED] -l` 显示其 `INTERP = /system/bin/linker64`，入口点 `[REDACTED]` —— 即 **ELF 可执行文件伪装成 `.so` 打包进 APK**（利用 `lib/<abi>/` 目录自带可执行位，绕过“应用无安装未知应用权限”的限制）。交叉印证（P0）：`/proc/<pid>/status` 的 `Name` 字段直接就是 `libloader64.so`。
- `libloader64.so`（200 KB）为**进程内 ELF 装载器**：字符串表含 `"%s" is too small to be an ELF executable`、`%s: load executable not supported!`、`execv`。
- `libuserkernel64.so`（4.17 MB）为**用户态内核层**：动态符号表 279 条中 **268 条为 UND（导入）、0 条定义为导出函数**；它**导入** `open/openat/stat/mmap/ioctl/socket/execve` 等真实 libc 调用，却不向外界提供任何符号。其字符串表含 `vma:%u, dentry:%u, inode:%u, file:%u`（**用户态 VFS 对象模型**）、`%s/titan-memfd-inode-%lu`、`%s/titan-tmp-inode-%lu`、`fscache.bin`、`sys_memfd_create`。

> 以上三项（`INTERP`、符号表统计、字符串表）均为 **P1** 层级取得，因为 `/data/app/*/<pkg>*/lib/arm64/` 在无 root 下为 `Permission denied`。其中 `libloader64.so` 作为可执行体这一事实，另由 **P0** 的进程 `Name` 字段独立佐证。

---

## 5. 架构模型

### 5.0 架构本质：外部可观测的三类处理路径

**这是理解本产品最关键的一节，也是本版报告确定性分层的核心。**

> **术语说明（重要）**：A / B / C 描述的是**「请求 / 对象访问的处理结果与语义路径」**，而**不是「内部确定存在的三个实现分支」**，也**不是「系统调用类型」**。
>
> 因为像 `/proc/cpuinfo` 这类对象，一次访问要经过 `openat()` → `read()` 等多个系统调用：其中 `openat` 的外部结果可能表现为 C 路径，`read` 的外部结果可能表现为 B 路径。把“cpuinfo 属于 B 分支”说成“cpuinfo 是 B 类系统调用”是不准确的。

客户机的每一次**请求/对象访问**，从外部行为看，处理结果可分为三类：

| 路径 | 外部可观测语义 | 是否必然到达宿主内核 | 典型请求 | 确定性 |
|---|---|---|---|---|
| **A · 宿主能力复用 / 透传语义表现** | 行为与宿主 Linux 语义一致 | **不能唯一确定**。可能直接透传，也可能拦截后转发，或由内部实现后再对接宿主 | `mmap`、`futex`、`nanosleep`、`clock_gettime`、`getrandom` | **K2** |
| **B · 合成 / 投影** | 返回值或内容由客户机侧构造，不呈现宿主真实值 | 外部结果表现为**未使用宿主真实语义**；内部是否完全未进内核不能唯一确定 | 身份类 `getuid`/`getresuid`/`getpid`/`capget`；以及 `/proc/{status,cpuinfo,meminfo,version,uptime}` 等对象的**读取结果** | **K1 结果 + K3 内部机制** |
| **C · 重定向 / 虚拟文件系统语义表现** | 对象落到客户机自己的存储体系或命名空间，路径/偏移被改写 | 外部可观测到真实 mmap/页缓存语义，但内部路径不唯一 | `openat("/system/…")`、`stat`、`/proc/<pid>/maps` 的**展示层** | **K1 结果 + K2/K3 内部机制** |

**A 与 C 的外部表现都可能到达宿主内核能力；区别在于外部参数/命名空间是否被改写。B 的外部结果完全不呈现宿主真实值。**
这个区分比“是否在用户态”更本质 —— 三者都在用户态被决定，但只有 B 在外部结果上是“真虚拟”。

#### 证据

**分支 B —— 实测（C 级 / P2 对照 P0）**

同一个进程，两侧自我描述完全不同：

| 观测项 | 客户机视角 (P2) | 宿主内核真相 (P0) |
|---|---|---|
| `su -c id` | `uid=0(root)` | uid **10383** |
| `CapEff` / `CapPrm` | `0000003fffffffff` | `0000000000000000` |
| `Seccomp` | **0** | **2**（且 2 层过滤器） |
| `/proc/cpuinfo` | Cortex-A53 × 8 | Snapdragon 8 Gen 2 |
| `/proc/meminfo` | 4,063,232 kB | 15,496,684 kB |

**分支 C —— 实测（C 级 / P2 对照 P1）**

客户机读 `/proc/self/maps` 得到：`/system/lib64/libnetd_client.so`，dev `03:08`，ino `3080`；而宿主侧同一映射是：`…/androidfs_10.0.0/system/readonly.bin`，dev `fd:26`，ino `118337`。

⇒ **真实的 mmap 确实发生了**（真页缓存、真零拷贝、页与其它客户机进程共享），**只是展示层被改写**。这是“该架构在**文件访问路径上具备结构性优势**”的**机制依据**，但**不构成性能结论**（见下文「性能含义」）。内部是否还有额外用户态文件系统层，属 **K3**。

**分支 A —— 行为高度支持，但非唯一实现（K2）**

本报告**没有直接观测到“透传”这一动作本身**。它是从以下约束反推的候选模型：

1. 客户机进程映射的是**宿主** bionic（`/apex/com.android.runtime/lib64/bionic/libc.so`）；
2. 客户机 SF 映射**宿主** `/vendor/lib64/vendor.qti.hardware.display.mapper@*.so`；
3. 客户机 SF 持有**宿主** `/dev/kgsl-3d0`（322 处 mmap，宿主 SF 为 840 处，同一驱动路径）；
4. 外部未观测到独立客户机内核的命名空间/设备/挂载证据，任何设备访问的外部表现都落到宿主驱动路径；
5. 若全部系统调用都进用户态处理，`libuserkernel64.so` 必须导出完整 syscall 实现，但实测其动态符号表 **279 条中 268 条为 UND、0 条为导出函数**。

⇒ “部分系统调用最终利用宿主内核提供的能力”是**行为高度支持的候选架构解释**。但必须诚实指出：

> **“过滤器直接放行”与“拦截后立即转发”在外部行为上完全等价，本报告的手段无法区分二者。**
>
> 甚至理论上还存在：
>
> ```text
> guest
>   ↓
> 虚拟 syscall handler
>   ↓
> 内部判断
>   ↓
> 内部用户态实现
>   ↓
> host 某个通道
>   ↓
> host kernel
> ```
>
> 从最终行为上也可能表现得非常像。
>
> 因此分支 A 标注为 **K2（行为高度支持，非唯一实现）**。

**候选分支 D —— 拦截并拒绝 / 降级（U 级 / K3，未证实）**

理论上还需一类“不允许到达宿主内核”的调用：`mount`、`umount`、`ptrace`、`reboot`、`init_module`、`setns`、`unshare`、`chroot`、`pivot_root`。现有数据中 `libuserkernel64.so` 含 `PTRACE_SEIZE` / `PTRACE_GETREGS` / `PR_SET_SECCOMP` 等常量，提示可能存在专门处理，但**未取得任何直接证据**，故列为 **U 级候选 / K3**。

#### 性能含义（**机制推论，非实测**）

| 分支 | 每次调用的外部可观测代价 |
|---|---|
| A | 外部表现接近宿主内核原生路径；但内部是否额外拦截无法判定 |
| C | 一次外部参数改写 + 宿主内核原生路径（真页缓存 / 真零拷贝） |
| B | 外部结果由用户态构造 —— 比真内核路径更快（但只适用于身份与硬件信息类调用） |

> ⚠️ **本报告未做任何性能测量。** 没有 syscall latency、`mmap`/`fork`/`futex`/I-O/GPU 任何一项 benchmark，也没有与宿主原生进程的对照实验。
>
> 因此**不能得出“性能接近原生”这类结论**——那是另一个层级的主张。
>
> 现有证据只支持一个**结构性判断**：
>
> **该架构具备“外部行为上复用宿主内核路径、避免完全系统调用模拟开销”的结构性表现**，因为 A 路径的外部语义直通宿主，C 路径只在参数/命名空间层做改写。
>
> **这是机制推论，不是实测性能结论。K2。**

#### 定位结论

> **现有观测不足以支持将其归类为完整 LibOS。**
>
> 真 LibOS / 用户态内核通常还需覆盖 syscall 语义、进程抽象、虚拟内存抽象、信号语义、fd 语义、文件系统语义、网络、调度语义、同步与 IPC 等全套抽象，而**本报告已明确排除网络维度**，其余维度也未逐项验证。
>
> **现有证据更支持**将其描述为：
>
> **「在宿主 Android 环境中构造出具有独立 Android 用户空间、进程语义、系统信息视图、存储体系及设备接口的运行环境；其外部行为高度吻合一个系统调用投影与设备仿真层。」**
>
> 但黑盒实验无法据此唯一确定其内部各子系统究竟是直接复用宿主内核能力、通过用户态代理实现，还是采用自有实现后再与宿主系统对接。
>
> 对于网络、文件系统、系统调用处理等部分，本报告仅根据可观测行为建立候选架构模型，**不将其中任一实现路径视为已经证实的内部代码结构。**

**一个直观比喻**（仅为帮助理解，非证据）：

> 真 LibOS 是“自己盖了一栋新房子”——从地基到水电管线全部自建；
>
> 本产品从外部看，像“租了宿主这套房子，但把门牌号、水电表、身份证全换成了另一套房子的”——**墙、水管、电路的外部表现仍像宿主的，只是从外面看起来完全是另一栋房子**。
>
> 但注意：黑盒无法确认它是否在墙内还加装了自己的管道系统。

### 5.1 分层视图（确定性标注）

```text
┌─────────────────────────────────────────────────────────────────────┐
│ 宿主 Linux 内核 5.15.167（真实）                                     │
│   真实系统调用 · 真实 procfs · 真实 GPU 驱动 · 真实 VMA              │
└─────────────────────────────────────────────────────────────────────┘
      ▲  ① 外部可观测为宿主能力路径；内部是否直接进入宿主内核为 K3
┌─────┴───────────────────────────────────────────────────────────────┐
│ L0  第 2 层 seccomp 过滤器（由客户机虚拟内核安装，全树 85 进程继承）  │
│     → 截获/投影特定路径的 openat/read，返回合成内容                  │
├─────────────────────────────────────────────────────────────────────┤
│ L1  用户态内核层  libuserkernel64.so (4.17MB，零导出符号)            │
│     · 用户态 VFS 对象模型 (vma/dentry/inode/file)                    │
│     · 虚拟 PID / UID / capability 映射                               │
│     · /proc 内容合成（→ memfd:titan-tmp-inode-N）                    │
│     · @titan-pipe-* 外设代理通道                                     │
├─────────────────────────────────────────────────────────────────────┤
│ L2  进程内 ELF 装载器  libloader64.so / libloader32.so (各 200KB)    │
│     · 从 readonly.bin 按偏移 mmap 客户机 ELF 并自行重定位            │
├─────────────────────────────────────────────────────────────────────┤
│ L3  客户机 Android 10 系统栈（85 进程）                              │
│     init / zygote64+32 / system_server / surfaceflinger /          │
│     adbd(6556) / Magisk 26.0 / LSPosed / Zygisk64+32 / 141 个应用    │
├─────────────────────────────────────────────────────────────────────┤
│ L4  存储层：私有明文容器（非挂载、非加密）                            │
│     [REDACTED] 卷组 → [REDACTED] 分区超级块 → [REDACTED] 明文 mmap 块容器              │
│     system 1.45GiB / vendor 30MB / data + 64MiB fscache / root+boot │
├─────────────────────────────────────────────────────────────────────┤
│ L5  宿主表示层：MyNativeActivity1 单 Activity + 宿主 SurfaceFlinger  │
└─────────────────────────────────────────────────────────────────────┘
```

> 图中 L0/L1 的“截获/投影”是 **K1 可观测结果**；“用户态内核层”是 **K2 候选解释**；其内部具体实现路径为 **K3**。

### 5.2 双向对照表（本报告的核心证据）

同一个进程，两套自我描述：

| 维度 | 客户机自我描述 (P2) | 宿主内核事实 (P0) | 外部手段 |
|---|---|---|---|
| PID | 1 / 43 / 60 / 249 | 7098 / 7227 / 7263 / 7957 | 投影/改写 `getpid` 族的外部结果 |
| UID | 0 | 10383 | 投影/改写 `getuid` 族的外部结果 |
| Capability | 全 `0x3fffffffff` | `0` | 投影/改写 `capget` 的外部结果 |
| Seccomp 自身状态 | 0 | 2（2 层过滤器） | 投影 `/proc/self/status` |
| 内核 | 4.14.42-titan | 5.15.167 | 合成 `/proc/version` |
| CPU | Cortex-A53 × 8 | 骁龙 8 Gen 2 | 合成 `/proc/cpuinfo` |
| 内存 | 3.9 GB | 14.8 GB | 合成 `/proc/meminfo` |
| `/system` 来源 | ext4 块设备 | `readonly.bin` 文件映射 | 合成 `/proc/mounts` + maps |
| cgroup | `cpu:/apps` | 6 控制器 + `/uid_10383/pid_6839` | 合成 `/proc/<pid>/cgroup` |

### 5.3 系统启动流程（观测 + 推定）

1. **宿主实例引导** —— 宿主 zygote fork 出 `:instance1`；加载 `libVPhoneGaGaLib.so`，建立 JNI 通道，打开 `readonly.bin` 系列容器，读取 [REDACTED] 超级块。
2. **虚拟内核初始化** —— `:instance1` fork `titan64_0:kernel`；该进程**为自己安装第 2 层 seccomp 过滤器**；解析 [REDACTED] 索引与 [REDACTED] 超级块，构建用户态 VFS；挂载虚拟 Boot 分区（`root/block.img`）。
3. **系统调用虚拟化上线** —— 此后 fork 出的所有进程均继承 seccomp 过滤器，进入“客户机”语义空间：PID / UID / capability / `/proc` 全部被投影。
4. **特权进程孵化** —— 客户机 init 被虚拟内核拉起后，`magiskd`(+0.8s) / `lspd`(+0.9s) / `zygiskd64`(+3.0s) / `zygiskd32`(+6.4s) 依次出现，其在宿主侧的**真实父进程均为虚拟内核**（32 位链路的真实父进程是 32 位虚拟内核）。
   **机制未定论**：可能是虚拟内核直接孵化，也可能是虚拟内核以 `PR_SET_CHILD_SUBREAPER` 身份接收了 daemonize 后重父化的孤儿进程 —— 详见 ARCHITECTURE.md §1.3。**K3。**
   与此同时，客户机侧被投影出一棵“符合真机形态”的逻辑父子树（`init(1) → magiskd(43) → {lspd(56), zygiskd64(259)}`），该树未必对应真实父进程。
5. **系统服务与图形** —— `titan64_1:init` 解析 `init.rc` 拉起约 70 个系统服务；客户机 SurfaceFlinger 通过 `@titan-pipe-1-framebuffer` 把合成结果交给宿主单 Activity 显示；相机 / GPS / 通信 / 传感器 / 指纹 / 输入 分别走各自的 `@titan-pipe-1-*` 通道。
6. **客户机 adbd** —— 监听 6556（`android.host.adb.port=6556`），提供内部调试入口。

### 5.4 与 gVisor 的定位差异（不宜比较复杂度）

| 维度 | gVisor（真 LibOS） | VPhoneGaGa 3.4.0 |
|---|---|---|
| 系统调用处理 | **全部**拦截，**全部**在用户态重实现语义 | **外部语义表现为分流**：A 宿主能力复用 / B 合成 / C 重定向；内部是否全拦截、部分拦截或直接透传，**黑盒不可区分** |
| 内存管理 | 自建地址空间抽象与页表（**物理页仍来自宿主 mmap**） | **外部观测复用宿主 VMA + mmap 语义**；内部是否直接复用不能唯一确定 |
| CPU 调度 | **两者外部均由宿主 CFS 完成**；gVisor 仅在 syscall 语义层模拟调度相关行为；VPhoneGaGa 连语义层也直接透传 | 同左，但内部实现路径为 **K3** |
| 进程隔离 | 完整沙箱 | **无任何 namespace，同 uid（K1）** |
| 客户机“看到的” | 一个由 sentry 实现的独立内核抽象 | 一个**按路径分发的合成投影（K1 结果）** |
| 本质 | **“我造了一个内核”** | 从外部看，**“我演了一个内核”**；内部是否另有实现无法黑盒判定 |
| 性能画像（机制层） | 每个系统调用都有用户态处理开销 | 外部表现仅一次边界检查 + 少量路径改写（**机制推论，本报告无性能实测**） |
| 核心工程量 | 内核语义完备性（网络栈、内存、文件系统全部自建） | `/proc` 全字段投影自洽性 + Magisk 生态兼容 + 机型适配 |

> **本表不含网络维度** —— 见 §7 第 10 条，本报告不就网络架构作任何结论。

> **不是贬低其工程价值**：真正稀缺的是 (1) 把完整 Android 10 跑在应用沙箱内、(2) 明文 mmap 容器带来的零拷贝代码共享、(3) 在零宿主特权下跑通 Magisk 生态。但复杂度分级应实事求是 —— 二者的难度不在同一维度，无法直接比“谁更难”。

---

## 6. 结论更正表

本节主动列出**被推翻或更正的判断**，包括本报告 AI 辅助分析自身犯的错误。

| # | 早期结论 | 现判定 | 依据 | 层级 |
|---|---|---|---|---|
| 1 | “[REDACTED] 加密镜像仅内存解密、磁盘无明文” | **推翻** | 映射偏移处可直接读到明文 ELF 与 ARM64 指令 | P1 |
| 2 | “完全抛弃 ext4/f2fs” | **更正** | 上层是私有容器；客户机被**伪装**成 ext4 块设备 | P2 |
| 3 | “`androidfs.bin` / `superblock.bin` 是核心镜像文件” | **更正** | 分别为 64 B / 16 B 的元数据与超级块 | P1 |
| 4 | 魔数写作 `[REDACTED]/[REDACTED]/[REDACTED]` | **补充** | 磁盘裸字节序为 `[REDACTED]/[REDACTED]/[REDACTED]`（16 位小端半字） | P1 |
| 5 | “四层嵌套**独立**进程树” | **更正** | 无 PID/UTS/USER/IPC namespace，同 uid；“独立”不成立 | P0/P1 |
| 6 | “宿主 App → 虚拟内核”父子关系 | **更正** | 二者是宿主 zygote 的**兄弟**；虚拟内核父进程是 `:instance1` | P0 |
| 7 | “接管所有客户机 SVC 内核陷入指令” | **更正** | 拦截在 **seccomp 层**，非 SVC 指令级；亦非 ptrace（`TracerPid=0`） | P0 |
| 8 | **【本报告 AI 误判】**“未检出系统调用拦截” | **更正** | `Seccomp_filters` 1→2 的分层证据确凿 | P0 |
| 9 | **【本报告 AI 误判】**“cpuset 论断被推翻” | **更正** | 受控实验证明客户机树常驻 `top-app`，不随 `instance1` 降级 | P0 |
| 10 | “GPU 零拷贝直通为 SS 级壁垒” | **归因更正** | 外部表现为宿主驱动路径；内部实现路径黑盒不可区分 | P1 / K3 |
| 11 | “纯用户态模拟 Root 状态机” | **修正** | 实际运行的是 **Magisk 26.0 体系**（`26.0:MAGISK:R`），而非自研状态机；但**未做官方构建 hash 对照**，故不称“官方原版” | P2 |
| 12 | “复杂度远超 gVisor” | **不成立** | 二者路线不同，不可直接比较 | — |
| 13 | “系统运行日志脱离宿主日志体系” | **补充** | 日志存于**外部存储**且**已加密** | P1 |
| 14 | “宿主 SF 仅识别单一渲染窗口” | **弱化** | 至少 3 个宿主窗口共存；准确说法是“客户机图形汇聚到单一 `MyNativeActivity1`” | P0 |
| 15 | 未提及 `targetSdk=29` | **新增** | 当前实现路线的**重要兼容条件之一**（是否为必要条件尚未验证） | P0 / K3 |
| 16 | 未提及 `@titan-pipe-*` 通道 | **新增** | 外设代理的真实机制，且**无需 root** 即可观测 | P0 |
| 17 | **【新增】**“Magisk/LSPosed/Zygisk 由虚拟内核**直接孵化**” | **弱化 + 机制未定论** | 观测事实是“宿主侧真实父进程为虚拟内核”；但客户机被显示的 PPid 是**重建过的逻辑树**（`magiskd`→`1` 而真实为 `7024`），指向 `PR_SET_CHILD_SUBREAPER` 重父化的可能。详见 [ARCHITECTURE.md](ARCHITECTURE.md) §1.3 | P0 + P2 / K3 |
| 18 | **【新增】**“它是一个用户态 LibOS / 虚拟内核” | **重新定位** | 改为“**系统调用投影与设备仿真层**”的外部行为模型：实测证明只有身份与硬件信息类调用被用户态合成（分支 B），文件系统类调用是**真实 mmap + 展示层改写**（分支 C），其余外部行为与宿主内核语义一致（分支 A）。但 A/B/C 是**外部语义路径**，不是内部确定实现分支。详见 §5.0 | P0 + P1 + P2 / K2 + K3 |
| 19 | **【本版新增】**“最终表现为复用宿主内核路径 = 内部实现复用宿主操作系统” | **降级** | 外部行为只能约束内部架构，不能唯一确定内部实现。网络、文件系统、系统调用处理均可能为宿主 socket/代理/用户态协议栈/自有实现/混合。详见 §0 与 §5.0 | K3 |
| 20 | **【本版新增】**“A 透传 / B 合成 / C 重定向是内部三个实现分支” | **重新定义** | 改为“从外部行为观察到的三类处理结果/语义路径”，不宣称为内部确定存在的三个实现分支 | K2 + K3 |

### 6.1 本轮「降级绝对措辞」审校（学术措辞收紧）

本节记录一次**针对“把强推断写成已证明”的系统性审校**。不改数据，只改结论的强度。

| # | 原措辞（过强） | 改为 | 理由 |
|---|---|---|---|
| 21 | “第 2 层**只能**由虚拟内核安装” | “**现有证据最支持**由虚拟内核在自举阶段安装；**具体安装调用者尚未被直接观测**” | 时间/拓扑相关性 ≠ 因果证明；仍存在其他理论替代路径 |
| 22 | “**按路径分别 hook 后拼装**” | “**与接口/路径级投影模型高度吻合**” | 原句是实现机制断言；实际观测只能支持“与某实现模型吻合” |
| 23 | “memfd **就是**这些假 /proc 文件的实体” | “只能证明**存在大量匿名/临时内存对象与用户态虚拟文件实现相关**；与上述实现模型高度吻合” | 超出证据边界，现象相关 ≠ 实体同一 |
| 24 | “**不是** LibOS” | “**现有观测不足以支持**将其归类为完整 LibOS；现有证据更支持…混合架构” | 全称否定无法证明；本报告已主动排除网络维度，不具备穷尽判断的条件 |
| 25 | “**系统调用**三分支” | “**请求处理的三类路径**” | `/proc/cpuinfo` 等对象一次访问含 `openat`+`read`，两条路径不同；不是“系统调用类型” |
| 26 | “**性能接近原生**” | “具备**外部行为上复用宿主内核路径、避免完全系统调用模拟开销**的结构性表现（**机制推论**）” | 本报告**未做任何性能测量**（无 syscall/mmap/fork/I-O/GPU benchmark） |
| 27 | “targetSdk=29 是架构成立的**前提**” | “是当前实现路线的**重要兼容条件之一**；是否为**必要条件尚未经验证**” | 未做 targetSdk=30/31 的对照实验 |
| 28 | “启动瞬间继承并**永久锁定**” | “在启动瞬间获得**独立于 `instance1` 后续状态变化**的调度归属，并在本次实验窗口内保持 `top-app`” | 只观测了一次 HOME 切换后约 6 秒；“永久”不可推出 |
| 29 | “**官方** Magisk 26.0” | “**Magisk 26.0 体系**（`26.0:MAGISK:R`）；未做官方构建 hash 对照，不称官方原版” | 版本字符串不能证明构建来源 |
| 30 | **【本版新增】**“宿主内核复用 + 系统调用投影 + 用户态文件系统/设备抽象” | “外部行为高度吻合系统调用投影与设备仿真层；内部实现路径为 K2/K3” | 外部可观测行为不能唯一确定内部实现 |

> **审校原则**：数字、命令、原始输出不动；**只把“已经证明”的陈述降为“现有证据最支持”或“黑盒不可区分”**。
> 宁可让结论看起来弱一点，也不能让证据链被人从措辞上拆掉。

---

## 7. 研究局限

| # | 局限 | 档位 |
|---|---|---|
| 1 | 第 2 层 seccomp 的**具体策略**未判定（需读 BPF 程序，属内核态信息） | **U / K3** |
| 2 | `:instance1` 与客户机树的 cgroup 继承机制在**两台设备上出现矛盾**，未定论 | **U / K3** |
| 3 | 仅 **1 个合格载体**（设备 A）；设备 B 因已 root + 定制 ROM 只能作为对照 | — |
| 4 | 客户机实例**非出厂状态**（存在后装 LSPosed 模块与 `su_arm64`） | — |
| 5 | 客户机内核版本、CPU 型号、内存容量**均为伪装值**，不可用于任何硬件推断 | — |
| 6 | `readonly.bin` 头中 +0x0C 起四个 32 位字段的**语义未解析** | **U / K3** |
| 7 | 未验证容器是否对部分分区启用 AES（`[REDACTED]` / `AES256CBC` 存在，但未见启用证据） | **U / K3** |
| 8 | 版本时效性：仅 3.4.0 / versionCode 3688；新版可能变更魔数、进程规则与伪造字段 | — |
| 9 | 边缘场景（冷启动、崩溃重启、降级路径）未覆盖 | — |
| 10 | **本报告不包含任何网络架构分析**；所有涉及网络的部分均已移除 | — |
| 11 | `magiskd` / `lspd` / `zygiskd64` 在宿主侧的真实父进程统一为虚拟内核，**其成因（直接孵化 vs. subreaper 重父化）未定论** | **U / K3** |
| 12 | 第 2 层 seccomp 的分支策略（透传 / `USER_NOTIF` / `TRACE`）未判定 —— **“过滤器直接放行”与“拦截后立即转发”外部行为等价，本报告手段无法区分** | **U / K3** |
| 13 | 是否存在“拦截并拒绝 / 降级”分支（`mount` / `ptrace` / `setns` / `unshare` 等）未证实 | **U / K3** |
| 14 | **本报告未做任何性能测量**（无 syscall latency / `mmap` / `fork` / `futex` / I-O / GPU benchmark，无宿主原生对照组），因此**不能得出任何性能结论** | **U / K3** |
| 15 | `targetSdk=29` 是否为架构成立的**必要条件**未经验证（未测试 targetSdk=30/31） | **U / K3** |
| 16 | 客户机调度归属是否会在长周期或进程重启后改变，**仅观测了一次 HOME 切换后约 6 秒的窗口** | **U / K3** |
| 17 | 客户机 Magisk 二进制的**构建来源未做 hash 对照**，不能断言其与官方发行包一致 | **U / K3** |
| 18 | 客户机 `/proc` 投影的**完整字段集未知** —— 只验证了 15 个路径两侧不一致，不等于只能这些被替换 | **U / K3** |
| 19 | **【本版新增】** 对外网络究竟是宿主 socket + 代理、用户态协议栈、内部虚拟网络设备，还是几种方案混合，**现有实验无法区分** | **U / K3** |
| 20 | **【本版新增】** 文件系统、系统调用处理、图形、root 等子系统的内部实现路径，外部黑盒无法唯一确定 | **U / K3** |
| 21 | **【本版新增】** A/B/C 三类路径是外部语义分类，不是内部实现分支；内部可能为混合或未观测路径 | **K2 / K3** |

---

## 8. 复现命令附录

> 每个区块标注所需权限层级。**P1 区块只能在对照设备 B 上执行。**

```bash
H=127.0.0.1:5555      # 宿主（原厂 OnePlus，无 root）
G=127.0.0.1:6556      # 客户机（需在 VM 画面中点“允许 USB 调试”）
R=192.168.10.3:5555   # 对照宿主（Redmi K30，有 root）—— 仅 P1 区块使用

# ═══════════ P0：无 root 即可复现 ═══════════

# ── 载体合格性 ──
adb -s $H shell 'command -v su; echo rc=$?'
adb -s $H shell 'ls /system/bin/su /debug_ramdisk 2>&1'
adb -s $H shell getprop | grep -E 'flavor|build.type|verifiedboot|flash.locked'
adb -s $H shell pm list packages | grep -iE 'magisk|kernelsu|lsposed'

# ── 软件版本 ──
adb -s $H shell dumpsys package com.vphonegaga.titan | grep -E 'versionName|versionCode|targetSdk'

# ── 进程拓扑与特权孵化 ──
adb -s $H shell ps -A -o PID,PPID,USER,NAME | grep -E 'titan(32|64)_'
adb -s $H shell 'for p in $(ps -A -o PID,NAME | grep -E "titan(32|64)_" | awk "{print \$1}"); \
  do printf "%s %s %s\n" $p $(awk "/^Uid/{print \$2}" /proc/$p/status) \
  $(awk "/^CapEff/{print \$2}" /proc/$p/status); done' | awk '{print $2,$3}' | sort | uniq -c

# ── ★ seccomp 分层（核心证据）──
echo "宿主对照："
adb -s $H shell "cat /proc/$(adb -s $H shell pidof com.android.systemui)/status" | grep Seccomp
echo "客户机全树："
adb -s $H shell 'for p in $(ps -A -o PID,NAME|grep -E "titan(32|64)_"|awk "{print \$1}"); \
  do awk "/^Seccomp/{print}" /proc/$p/status; done' | sort | uniq -c
# 期望：宿主 1 层；客户机全部 2 层

# ── 调度等级受控实验 ──
for P in <APP> <INSTANCE1> <KERNEL>; do
  printf "%-8s " $P; adb -s $H shell "grep cpuset /proc/$P/cgroup"
  echo "         oom=$(adb -s $H shell cat /proc/$P/oom_score_adj)"
done
adb -s $H shell input keyevent KEYCODE_HOME      # 切后台（会打断 VM 前台）
sleep 6
# 重复上面的循环 → 观察客户机树是否跟随 instance1
adb -s $H shell am start -n com.vphonegaga.titan/com.vphonegaga.titan.MyNativeActivity1  # 恢复

# ── ★ 外设代理通道枚举（无需 root）──
adb -s $H shell cat /proc/net/unix | grep -oE '@titan-pipe-1-[a-zA-Z0-9:=]*' | sort -u
adb -s $H shell cat /proc/net/unix | grep -c '@titan-process-worker-server'

# ── 权限边界确认（说明哪些必须 root）──
adb -s $H shell 'readlink /proc/<PID>/exe'   # 空输出
adb -s $H shell 'ls /proc/<PID>/ns'          # Permission denied
adb -s $H shell 'head -1 /proc/<PID>/maps'   # Permission denied
adb -s $H shell 'ls /proc/<PID>/fd'          # Permission denied
adb -s $H shell 'ls /data/data/com.vphonegaga.titan'   # Permission denied
adb -s $H shell 'ls /data/app/*/com.vphonegaga.titan*/lib/arm64'  # Permission denied


# ═══════════ P1：需宿主 root（仅对照设备 R）═══════════

# ── 命名空间（证明无隔离）──
adb -s $R shell "su -c 'ls /proc/<PID>/ns/; grep -c NSpid /proc/<PID>/status'"

# ── 真实可执行文件 ──
adb -s $R shell "su -c 'readlink /proc/<PID>/exe'"

# ── 存储容器格式（魔数两种字节序）──
B=/data/data/com.vphonegaga.titan/files/instance1/androidfs_10.0.0
adb -s $R shell "su -c 'od -A d -t x1 -N 32 $B/system/readonly.bin'"   # 41 54 49 54 = [REDACTED]
adb -s $R shell "su -c 'od -A d -t x1 $B/system/superblock.bin'"       # 42 50 55 53 = [REDACTED]
adb -s $R shell "su -c 'od -A d -t x1 -N 32 $B/androidfs.bin'"         # 53 46 44 41 = [REDACTED]
adb -s $R shell "su -c 'od -A d -t x1 -N 64 $B/root/block.img'"        # 41 4e 44 52 4f 49 44 21 = [REDACTED]
adb -s $R shell "su -c 'od -x -N 32 $B/system/readonly.bin'"           # 5441 5449 = [REDACTED]（od -x 视角）

# ── 内存映射与描述符 ──
adb -s $R shell "su -c 'grep readonly.bin /proc/<PID>/maps | head'"    # 验证真 mmap
adb -s $R shell "su -c 'ls -l /proc/<PID>/fd | grep -oE \"memfd:[^ ]*\" | sort -u'"
adb -s $R shell "su -c 'ls -l /proc/<PID>/fd | grep -oE \"(/dev|/dmabuf)[^ ]*\" | sort | uniq -c'"

# ── APK 组件元数据（不做指令分析）──
L=/data/app/*/com.vphonegaga.titan*/lib/arm64
adb -s $R shell "su -c '[REDACTED] -lW $L/libloader64.so | head -20'"     # INTERP=/system/bin/linker64
adb -s $R shell "su -c '[REDACTED] --[REDACTED] -W $L/libuserkernel64.so | awk \"{print \\\$7}\" | sort | uniq -c'"
adb -s $R shell "su -c 'strings -a $L/libuserkernel64.so | grep -E \"titan-|vma:|fscache\" | sort -u'"
adb -s $R shell "su -c 'strings -a $L/libp7zip.so | grep -E \"^7z|LZMA|AES|BCJ\" | sort -u'"

# ── 日志密文验证 ──
adb -s $R shell "su -c 'strings -a /sdcard/Android/data/com.vphonegaga.titan/files/instance1/logs/1/UserKernel.log | head'"


# ═══════════ P2：客户机内部 shell ═══════════

# ── ★★ 双向对照（同一进程两个视角）──
# 客户机侧（投影）
adb -s $G shell 'su -c id'
adb -s $G shell 'cat /proc/self/status | grep -E "Uid|CapEff|Seccomp|NoNewPrivs"'
adb -s $G shell 'cat /proc/cpuinfo | grep "CPU part" | head -2'
adb -s $G shell 'grep MemTotal /proc/meminfo; cat /proc/uptime; cat /proc/version'
# 宿主侧（真相）—— 先用 ps 找到 titan64_<虚拟PID> 的真实宿主 PID
adb -s $H shell ps -A -o PID,NAME | grep -E 'titan64_(1|43|60):'
adb -s $H shell 'cat /proc/<宿主PID>/status | grep -E "Uid|CapEff|Seccomp|NoNewPrivs"'
adb -s $H shell 'cat /proc/cpuinfo | grep "CPU part" | head -2'
adb -s $H shell 'grep MemTotal /proc/meminfo'

# ── ★ 伪造自证：同一状态三个答案 ──
adb -s $G shell 'head -2 /proc/self/mountinfo; head -2 /proc/mounts; mount | head -2'
adb -s $G shell 'ls -l /proc/1/exe; ls -l /proc/self/fd'   # 权限位与 fd 格式
adb -s $G shell 'ls /proc | grep -E "^[0-9]+$" | wc -l; ls /proc | grep -E "^[0-9]+$" | sort -n | tail -1'

# ── 客户机 root 形态 ──
adb -s $G shell 'magisk -v; magisk -V; ls -l /sbin/magiskinit'
adb -s $G shell 'su -c "ls -la /data/adb/ /data/adb/modules/"'
```

---

## 9. 发表建议

### 9.1 可以发表

- 全文为**行为观测**，未反汇编、未反编译，属架构分析与互操作性研究范畴。
- 观测在自有设备与自有授权副本上进行。
- 建议保留 §1.1 的 AI 辅助声明与 §8 的复现命令 —— **这是本报告可信度的主要来源**。
- 建议保留 §0 与 §5.0 的 **K1/K2/K3 确定性分层**，它是本版报告的核心方法论。

### 9.2 必须保留的声明

1. **AI 辅助声明**（§1.1），含自我更正的说明。
2. **权限分级表**（§1.2 / §1.3），明确每条结论由 P0 / P1 / P2 中的哪一层取得。**特别是**：主载体无 P1 层级，一切需要 root 的观测都来自对照设备 B。
3. **魔数的两种字节序**（`[REDACTED]/[REDACTED]/[REDACTED]` 与裸字节 `[REDACTED]/[REDACTED]/[REDACTED]`）。
4. **环境干扰项**（§2.4）：设备 A 无可用 root 但曾装 KernelSU；设备 B 已 root 且属性被重置、`getprop` 不可信。
5. **全文标注证据档位 A/B/C/U 与确定性层级 K1/K2/K3**，并保留 §7 的局限。
6. **方法论底线**：外部可观测行为能够约束内部架构，但通常不能唯一确定内部实现。

### 9.3 表述规范

删除所有“绕过 / 破解 / 欺骗 / 突破”字样，改为结果描述：

| ❌ 不写 | ✅ 改写为 |
|---|---|
| 绕过原生检测机制 | 第 2 层 seccomp 过滤器/投影层使 `getuid`/`capget` 返回虚拟值 |
| 突破单应用进程数量限制 | 客户机整树在启动瞬间继承 `top-app` 等级并在宿主降级后保持不变 |
| 适配幽灵进程查杀机制 | 客户机进程的 `oom_score_adj` 为 0，低于其宿主容器进程的 101 |
| 欺骗宿主优先级 | 客户机进程在启动瞬间获得独立于 `instance1` 后续状态变化的调度归属 |

### 9.4 不要写进报告

- 第 2 层 seccomp 过滤器的**绕过方法**。
- `readonly.bin` 的**提取、偏移表、重打包流程**。
- 使客户机 adbd**免鉴权**的任何方法。
- 虚拟 uid / capability 伪造的**实现细节**。
- 客户机内可读取的**隐私数据路径**。

> 原则：**“观测到了什么”可以公开；“如何改写它”一律不公开。**

### 9.5 本报告的增量价值

| 增量 | 说明 |
|---|---|
| **双向对照表**（§5.2） | 同一进程的两套自我描述。纯外部观测拿不到，是真正的护城河 |
| **`Seccomp_filters` 1→2 分层**（§4.3） | 用一个此前未被引用的内核字段，把“系统调用拦截”从猜想变为可计数的复现实验 |
| **投影的自证式破绽**（§4.5） | 用产品自身的 bug 证明它在投影/伪造，比任何推断都硬 |
| **`@titan-pipe-*` 通道枚举**（§4.6） | 外设代理的真实机制，且无需 root 即可取得 |
| **权限分级体系**（§1.2/§1.3） | 明确区分无 root 与 root 两类证据的来源 |
| **`targetSdk=29`**（§3） | 指出当前实现路线的重要兼容条件（未宣称其为必要条件） |
| **自我更正表**（§6） | 主动列出被推翻的结论，含本报告 AI 辅助分析自身的误判 |
| **K1/K2/K3 确定性分层**（§0 / §5.0） | 把“可证明的语义结果”与“行为支持的架构解释”“黑盒不可区分的内部实现”分开，避免把外部行为等同于内部实现 |
| **A/B/C 重新定义**（§5.0） | 从“内部三个实现分支”改为“外部可观测的三类处理结果/语义路径” |

---

*报告结束。所有 K1 结论均可由 §8 命令在相同环境下复现；K2/K3 结论应视为候选架构模型，而非已证实的内部代码结构。*
