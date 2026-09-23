# VPhoneGaGa 3.4.0 — Low-Level Architecture Forensics Report

| Item | Content |
|---|---|
| Report version | **v2.0** (dual-device controlled-experiment revision) |
| Previous version | v1.1 (deterministic-layering revision) |
| Companion document | [`垫片分层模型_进程与线程.md`](垫片分层模型_进程与线程.md) · [`复现路线与垫片设计.md`](复现路线与垫片设计.md) |
| Target | `com.vphonegaga.titan` **3.4.0** (versionCode 3688) |
| **Quick start** | ⭐ **[中文速览](架构速览.md)** · **[English overview](架构速览_EN.md)** — one-minute overview of the idea and its trade-offs (conjectural) |
| Official site | <https://vphoneos.com> |
| Related public patent | 《一种在安卓系统上运行虚拟安卓系统的方法》 · Publication No. **CN111026449B** (public document, reference only) |
| License | **MIT** — applies only to **this repository's own text and test code**; product names, trademarks, third-party binaries, and cited materials are **not covered** (see [`LICENSE`](LICENSE)) |
| Method | Pure runtime behavior forensics (no disassembly, no decompilation, no IDA / Ghidra / Frida) + **dual-device controlled experiments** |
| Carriers | 1 host device (OnePlus PJE110) + its built-in Android 10 guest instance |
| Permission tiers | **P0** host adbd (unrooted) · **P1** host root (**early comparison carrier only**) · **P2** guest-internal shell (shell / su) |
| **AI assistance** | **pi.dev (deepseek-v4-flash)** — accessed via API; used for observation planning, command sequencing, and text organization |
| Evidence grading | Every claim tagged **A / B / C / U**, plus the **permission tier P0/P1/P2** required to obtain it |
| **Determinacy levels** | **K1** directly proven / **K2** behavior strongly supports an architectural explanation / **K3** black-box indistinguishable |

[中文](./README.md)

---

## Positioning

> **A black-box runtime architecture study of VPhoneGaGa 3.4.0**
>
> Based on **system-behavior observation**, **cross-permission-tier forensics**, and **Host/Guest
> dual-device controlled experiments**, it **externally models** the product's **process model,
> syscall semantic projection, virtual filesystem, network control plane, storage container, IPC,
> and Android userspace execution environment**.
>
> **This report does not claim to reconstruct the product's internal source implementation.**
> K1 / K2 / K3 separate **experimental facts**, **strongly supported architecture explanations**,
> and **implementation hypotheses indistinguishable by black-box means**.

---

## Research Object and Sources

This report is an **independent third-party architecture analysis**. Sources:

| # | Material | Source | Nature |
|---|---|---|---|
| 1 | **The application** | The publicly distributed `com.vphonegaga.titan` 3.4.0 · official site <https://vphoneos.com> | publicly obtainable |
| 2 | **Public patent** | 《一种在安卓系统上运行虚拟安卓系统的方法》 · Application No. CN201911260873.5 · Publication No. **CN111026449B** | public document |
| 3 | **Observations** | `adb` / `ps` / `/proc` / self-compiled test programs on owned devices | self-produced |

**Method**: **system-behavior observation only (black box)**. Every judgment about internal architecture is a **K2/K3 candidate model**
and does not represent the product's real implementation; everything about the product is governed by official releases.

**Determinacy layering**: 【**K1**】 measured fact · 【**K2/K3**】 inference · 【**suggestion**】 design opinion.

> This is an independent third-party analysis and does not represent the vendor's position. **If the vendor requests it, this repository can be closed.**

---

## 0. Abstract

This report reconstructs the observable architecture of the closed-source Android virtualization
product **VPhoneGaGa 3.4.0**, using **unrooted host-side runtime observation** combined with
**a shell obtained from inside the guest VM**, and — new in this version — **dual-device controlled experiments**.

The methodological floor of this report is:

> **Externally observable behavior can constrain internal architecture, but usually cannot uniquely determine it.**
>
> The only way to break that limit is a **controlled experiment**: run the same test payload *inside*
> the target environment, collect its own return values, and compare them item by item against a
> real kernel. **The differences are direct evidence of the projection layer.**

Conclusions are therefore split into three levels:

| Level | Meaning | Permitted phrasing |
|---|---|---|
| **K1 · Directly proven** | Semantic facts provable from measured output (including controlled experiments) | "observed / reproducible / directly proven" |
| **K2 · Behavior strongly supports** | Candidate architecture model that fits the observations well | "best supported by current evidence / behavior strongly matches / candidate model" |
| **K3 · Black-box indistinguishable** | Internal implementation paths that external black-box experiments cannot uniquely decide | "cannot distinguish / cannot uniquely determine / still a candidate" |

Eight central findings:

1. **A syscall projection layer really exists — but it is not "hijacking SVC trap instructions"; it is a self-installed second seccomp filter.** The `Seccomp_filters` field in `/proc/<pid>/status` gives layered proof: host app processes carry **1** filter; all guest processes carry **2**. **K1.**

2. **`/proc` and identity-class syscalls are projected wholesale.** The same process gives two contradictory self-descriptions: the guest reports `uid=0` / full capabilities / `Seccomp: 0` / kernel 4.14.42 / Cortex-A53 / 4 GB RAM. The host kernel reports `uid=10383` / `CapEff=0` / `Seccomp: 2` / kernel 5.15.167 / Snapdragon 8 Gen 2 / 14.8 GB RAM. **K1.**

3. **Mount subsystem: the guest's permission model is inconsistent with the Linux permission model, and its `mount()` result cannot be explained by "the host kernel executing the same call under Linux permission rules".** Measured: inside the guest **any uid (including 10000 / 10123) can successfully `mount(tmpfs)`**, which a real Linux kernel cannot allow; and `mount` is open to all uids while `umount` is root-only (asymmetric). The model best fitting these facts is an **independent userspace mount-semantics handler** in the guest (K2), bounded by a `/proc/filesystems` whitelist; the host mount table never changes (K1). A "userspace layer forwards to another host interface" chain cannot be excluded (K3).

4. **Networking is a hybrid (data-plane / control-plane / info-plane conclusions differ).** A listening port created inside the guest appears in host `/proc/net/tcp` → **a real socket object exists in the host kernel (K1)**; `setsockopt(IP_RECVTTL/IP_PKTINFO/IP_RETOPTS)` succeeds on the host but returns `EINVAL` in the guest → **the control plane is intercepted by a userspace layer (K1)**; the guest's internal `/proc/net/tcp` is empty → **the info plane is projected (K1)**. The data-plane processing location is a candidate model (K2); whether userspace processing is layered on top cannot be decided (K3).

5. **Guest root is a Magisk 26.0 stack running inside the app UID.** The host has no usable root path; the guest's `magiskd / lspd / zygiskd64 / zygiskd32` have the **virtual kernel as their real host-side parent**; the parent shown inside the guest is a **reconstructed** logical tree. **K1 observation + K3 mechanism.**

6. **The storage layer is a private, plaintext, memory-mappable container.** The guest image is **not mounted through the kernel**; the host-side runtime carries it in a **read-only, directly memory-mappable** private format, and the block devices / filesystems the guest sees are **projected**. **K1 observation + K2 interpretation.**

7. **It is a "syscall projection and device-emulation layer" running inside an app UID, with seccomp as its interception boundary and userspace data models maintaining OS semantics.** Request handling falls — in externally observable behavior — into three **semantic paths**: **A host-capability reuse / passthrough**, **B synthesis / projection**, **C redirection / virtual filesystem**. These describe **externally observable processing results**, not three confirmed internal implementation branches. **K2 + K3.**

8. **This report treats no internal implementation path as proven.** For networking, filesystems, and syscall handling, candidate models are built from controlled-experiment results, clearly separating K1 results from K3 internal mechanisms.

In one sentence:

> Externally, it *acts out* a kernel; controlled experiments prove that its **identity, system info, mounts, and network control plane are indeed decided by userspace code**,
> while its **data plane (sockets, mmap, clocks) reuses host-kernel capability**. Which semantics are taken over by userspace and which are passed through has now been divided item by item by controlled experiments.

---

## 1. Methodology, Permission Tiers, and Compliance

### 1.1 Methodological core: dual-device controlled experiments

The previous version established that "external observation cannot uniquely determine internal
implementation." This version supplies the **experimental design that breaks that limit**:

> **Run the same self-compiled test payload on both the "real kernel" and the "projection layer",
> and compare syscall return values item by item.**
> **Differences are direct evidence of the projection layer; agreement means the path is passed through.**

| Design element | Description |
|---|---|
| Test payload | `-nostdlib -static` raw-assembly syscall program (no libc, no dynamic linking, no compiler runtime) |
| Interference removed | Issues `svc #0` directly without libc wrappers, so what is observed is kernel/projection behavior, not library behavior |
| Control group | Host (real Linux 5.15 kernel, shell uid 2000) |
| Experimental group | Guest (projection layer, shell uid 2000 / su uid 0) |
| Decision rule | Same UID, same path, same binary, different result ⇒ that semantic is decided by userspace |

This method upgrades several conclusions previously labeled **U (undetermined)** to **K1 (directly proven)**.

### 1.2 AI-assistance disclosure

| Item | Detail |
|---|---|
| AI interface | **pi.dev** (accessed via API) |
| Model | **deepseek-v4-flash** |
| Scope of involvement | Observation planning, command sequencing, raw-output organization, cross-checking, conclusion drafting, report writing, and EN/CN localization |
| Not involved | Every command was executed on real hardware; every output is a genuine terminal echo, not AI-generated or inferred |

**Risk that must be stated**: AI-assisted analysis produces errors. The misjudgments listed in
§7 "Corrections" were produced by this report's AI-assisted analysis and corrected after subsequent
measurement. They are listed not as a disclaimer but as a warning:
**this report's credibility comes from the reproducible commands in §9, the controlled-experiment
design in §1.1, and the determinacy layering in §0 — not from anyone's authority.**

### 1.3 Permission tiers (used throughout)

| Tier | Code | Identity | How obtained | Availability |
|---|---|---|---|---|
| Host adbd (**unrooted**) | **P0** | `uid=2000(shell)`, `context=u:r:shell:s0` | `adb connect 127.0.0.1:5555` | Host |
| Host root | **P1** | `uid=0(root)` | `su -c` (**early comparison carrier only**, Magisk Alpha) | Early comparison carrier |
| Guest-internal shell | **P2** | guest `uid=2000` → `su` → guest `uid=0` | `adb connect 127.0.0.1:6556` | Guest instance |

> **Note (important)**: the primary host carrier (OnePlus PJE110) **has no P1 tier** (no `su`, no magiskd).
> **P1 evidence comes from an early comparison carrier; it supplements verification and is not used to
> describe the current PJE110's live state.**
> Specific P1 structural observations (`/proc/<pid>/{ns,maps,fd}` etc.) appear in §2.2, §4.2, §4.4, §4.9, §4.13.
> This version's core increment (controlled experiments on mounts / networking / system-info projection)
> was **done entirely at P0 + P2**.

### 1.4 Actual permission boundaries per tier (measured)

| Observation target | P0 (unrooted host) | P1 (host root) | P2 (inside guest) |
|---|---|---|---|
| `ps -A -o PID,PPID,USER,NAME` | ✅ | ✅ | ✅ |
| `/proc/<pid>/status` (incl. `Seccomp` / `Seccomp_filters` / `CapEff` / `TracerPid`) | ✅ | ✅ | ✅ |
| `/proc/<pid>/{cgroup,oom_score_adj,cmdline}` | ✅ | ✅ | ✅ |
| `/proc/net/unix` (socket name enumeration) | ✅ | ✅ | ✅ |
| `/proc/{mounts,cpuinfo,meminfo}` | ✅ | ✅ | ✅ |
| `dumpsys` / `pm` / `getprop` | ✅ | ✅ | ✅ |
| `/proc/version`, `/proc/uptime` (host side) | ❌ DENIED | ✅ | ✅ |
| **`readlink /proc/<pid>/exe`** | ❌ | ✅ | ✅ |
| **`/proc/<pid>/ns/` (namespaces)** | ❌ DENIED | ✅ | ✅ |
| **`/proc/<pid>/{maps,fd,environ}`** | ❌ DENIED | ✅ | ✅ |
| **`/data/data/com.vphonegaga.titan/` (private data dir)** | ❌ DENIED | ✅ | — |
| **`/data/app/*/<pkg>*/lib/arm64/` (APK native libs)** | ❌ DENIED | ✅ | — |
| **Execute a custom binary inside the guest** | — | — | ✅ (`/data/local/tmp`) |

### 1.5 Techniques used

| Area | Technique | Tier |
|---|---|---|
| Process & scheduling | `ps`, `/proc/<pid>/{status,cgroup,oom_score_adj,cmdline}` | P0 |
| Kernel state fields | `Seccomp` / `Seccomp_filters` / `CapEff` / `NoNewPrivs` / `TracerPid` | P0 |
| IPC name enumeration | `/proc/net/unix` | P0 |
| **Controlled experiments** | **Self-compiled raw-syscall test programs (`-nostdlib -static`), run on both sides** | P0 + P2 |
| Mount capability testing | `mount` / `umount` syscalls + errno recording | P2 |
| Namespaces & memory mappings | `/proc/<pid>/{ns,maps,fd}` | P1 |
| Guest-internal view | The guest's own adbd (`127.0.0.1:6556`) shell + `su` | P2 |

### 1.6 Techniques explicitly *not* used

No disassembly of any SO/DEX. No decompilation. No IDA / Ghidra / Frida / Xposed.
No private image internals were parsed. **No packet capture, routing, or traffic analysis of any kind.**

### 1.7 Observation environment

- All observation was performed on **owned devices**, using public system commands (`ps` / `/proc`) and self-written test programs.
- Sources and determinacy layering are in the front-matter section **"Research Object and Sources"**.

### 1.8 Evidence grading and determinacy levels

| Grade | Meaning |
|---|---|
| **A** | Reproducible without root (**P0-reachable**) |
| **B** | Requires host root (**P1-reachable**; archived from the early comparison carrier) |
| **C** | Requires guest-internal shell (**P2-reachable**) |
| **U** | **Undetermined** with current instrumentation |

| Determinacy level | Meaning |
|---|---|
| **K1** | Directly proven: semantic facts provable from measured output (incl. controlled experiments) |
| **K2** | Behavior strongly supports a candidate architecture model, but it is not the only implementation |
| **K3** | Black-box indistinguishable: internal implementation paths external behavior cannot uniquely decide |

> **Principle**: the closer a conclusion is to "internal mechanism", the lower its determinacy.
> Phrasings such as "reuses the host kernel", "userspace proxy", "own implementation" are treated
> as K2/K3 unless explicitly marked K1.

#### 1.8.1 Standard sentence patterns (used throughout)

To avoid writing "result" as "implementation", the report uniformly uses the following patterns.
**K1 describes only the observable fact itself, never an internal implementation.**

| Level | Pattern | Example |
|---|---|---|
| **K1** | **The observable fact is X.** | "Inside the guest, uid 10000 can successfully `mount(tmpfs)`." |
| **K2** | **The architecture model best fitting X is Y.** | "The model best fitting that difference is an independent userspace mount-semantics handler." |
| **K3** | **All of the following can explain X: Y1 / Y2 / Y3. Current experiments cannot tell them apart.** | "A userspace-only mount table / userspace handling then forwarding to another host interface / a hybrid — all three explain it; indistinguishable." |

**The narrowing principle** (must be followed):

| May be asserted as K1 | Must NOT be asserted as K1 (downgrade to K2/K3) |
|---|---|
| guest `mount()` and host `mount()` **return different results** | guest `mount()` **is implemented by `libuserkernel64.so`** |
| a corresponding socket object **exists** in the host kernel | the socket data plane **is definitely handled directly by the host TCP/IP stack** |
| the host kernel **refuses** the call while the guest **accepts** it | the guest **never calls the host kernel at all** |
| the guest `/proc` output **systematically differs** from host truth | the guest `/proc` **is synthesized by some hooked function** |

---

## 2. Test Devices and Environments

### 2.1 Host device (primary carrier)

| Item | Observed value | Tier |
|---|---|---|
| Brand / model | OnePlus / **PJE110** | P0 |
| SoC | Qualcomm **SM8550** (Snapdragon 8 Gen 2, codename `KALAMA`) | P0 |
| CPU | 8 cores: 3×`0xd46` (Cortex-A510) / 2×`0xd47` (A715) / 2×`0xd4d` (A710) / 1×`0xd4e` (X3) | P0 |
| RAM | 15,496,684 kB ≈ **14.8 GiB** | P0 |
| OS | **ColorOS/OxygenOS 15.0.0.870(CN01)**, Android **15** / SDK **35** | P0 |
| Kernel | `5.15.167-android13-8-o-01144-gdc8278c1c5f9` | P0 |
| Integrity | `ro.build.flavor=qssi-user`, `type=user`, `tags=release-keys`, **bootloader locked**, `verifiedbootstate=green` | P0 |
| **Root status** | **No usable root**: `command -v su` fails, `/system/bin/su` absent, no magiskd, no root processes | P0 |

### 2.2 Comparison carrier — P1 (host root) source 【archived】

> This version's core increment was done at P0 + P2, but **the P1 observations obtained earlier on a
> root-enabled comparison carrier are archived in full and retained**, not deleted because the carrier
> is not present. Below is that carrier's qualification record.

| Item | Observed value | Tier |
|---|---|---|
| Brand / model | Redmi / **Redmi K30 5G** (`picasso`) | P0 |
| SoC | Qualcomm **SM7250** (Snapdragon 765G) | P0 |
| OS | **LineageOS 22.2 UNOFFICIAL** (Android 15 / SDK 35) | P0 |
| Build | `lineage_picasso-userdebug 15 BP1A.250505.005 eng.cnmrli test-keys` | P0 |
| **Root status** | **Magisk Alpha running**: package `io.github.vvb2060.magisk` v`c3db2e36-alpha`; `magiskd` (uid 0) alive | P0 obs / **P1 source** |
| Property reliability | **Unreliable**: `release-keys` contradicts `test-keys`, `user` contradicts `userdebug` ⇒ **Magisk property resets active**, `getprop`-based conclusions not trusted | P0 |

> This carrier **cannot validate "no host root required"**; it only supplies the P1 tier and a control.
> Conclusions from it are tagged 【P1】 below.

### 2.3 Guest instance — running inside the host (P2 source)

A guest-internal shell was obtained through the guest's own adbd (`adb connect 127.0.0.1:6556`).
Its ADB banner advertises `product:cancro model:Nexus device:android`.

| Item | Guest self-description | Host-kernel reality | Tier |
|---|---|---|---|
| OS version | Android **10** / SDK **29** | Host Android 15 / SDK 35 | P2 / P0 |
| Fingerprint | `samsung/cancro/android:10/KOT49H/eng.build.20220315.203416:user/release-keys` | `OnePlus/PJE110/…:15/…` | P2 / P0 |
| Model | `model=Nexus`, `brand=samsung`, `device=android`, `name=cancro` | PJE110 / OnePlus | P2 / P0 |
| Kernel | `4.14.42-titan (titan@ubuntu) gcc 4.8.4 #34 SMP PREEMPT 2019-11-09` | `5.15.167-android13-8-…` | P2 / P0 |
| CPU | Cortex-A53 (`0x801`) × 8 | Snapdragon 8 Gen 2 (`0xd46/0xd47/0xd4d/0xd4e`) | P2 / P0 |
| RAM | 4,063,232 kB ≈ **3.9 GB** | 15,496,684 kB ≈ **14.8 GB** | P2 / P0 |
| `/data` size | 933 GB | 933 GB (**not disguised — leaked**) | P2 |
| Root | **Magisk 26.0** (`26.0:MAGISK:R` / `26000`) | uid 10383 / CapEff 0 | P2 / P0 |
| Process count | ~85–100 inside the guest | ~98–101 `titan*` on the host | P2 / P0 |

> ⚠️ **This guest instance may not be factory-fresh**: modules may have been installed inside it.
> Any reference to "the guest ships LSPosed" must state this.

### 2.4 Environmental confounders (must be stated)

| Confounder | Impact | Handling |
|---|---|---|
| KernelSU manager previously installed; `/data/adb` exists | Shows the device had been root-attempted | Stated; **but currently no usable root path** |
| A global VPN-type app may run on the host | Affects interpretation of egress paths | Network conclusions are limited to the **socket control plane**, not routing |
| Post-installed modules may exist inside the guest | Guest is not a clean instance | Stated |

---

## 3. Software Version

| Item | Value | Tier |
|---|---|---|
| Package | `com.vphonegaga.titan` | P0 |
| **Version name** | **3.4.0** | P0 |
| Version code | **3688** | P0 |
| minSdkVersion | **21** | P0 |
| **targetSdkVersion** | **29** (Android 10) | P0 |
| Instance dir | `files/instance1/androidfs_10.0.0/` | P2 |

> **`targetSdk=29` is one important compatibility condition of the current implementation route**:
> pinning targetSdk at Android 10 significantly reduces friction from Android 11+ scoped storage,
> package visibility, background-execution, and process-count limits.
>
> ⚠️ **But "it is a necessary condition for the architecture" has not been verified by controlled
> experiment** (targetSdk=30/31 untested). Marked **U / K3**.

**Guest image**: Android 10, built 2022-03-15, security patch level 2019-09-05. 【P2】

---

## 4. Observations

> Every observation is tagged with an **evidence grade** and the **permission tier** required.
> Interpretations about internal mechanisms are additionally tagged **K1 / K2 / K3**.

### 4.1 Process topology — **Grade A / P0 / K1**

Measured on the host side:

```text
host zygote64
├── com.vphonegaga.titan              uid 10383   cpuset:/foreground
└── com.vphonegaga.titan:instance1    uid 10383   cpuset:/foreground
    └── titan64_0:kernel              ← guest virtual kernel (64-bit), Name=libloader64.so
        ├── titan32_0:kernel          ← guest virtual kernel (32-bit), forked by the 64-bit one
        ├── titan64_1:init            ← guest init (real parent = virtual kernel)
        │   ├── titan64_59:netd / 62:zygote64 / 111:surfaceflinger
        │   ├── titan64_119:adbd      ← guest's own full adbd (listening on 6556)
        │   ├── titan64_185:su
        │   └── titan64_199:system_server
        ├── titan64_43:magiskd        ← real host parent = virtual kernel, **not init**
        ├── titan64_56:lspd           ← real host parent = virtual kernel
        ├── titan64_229:zygiskd64     ← real host parent = virtual kernel
        └── titan32_504:zygiskd32     ← real host parent = **32-bit virtual kernel**
```

**Naming rule**: `titan{32,64}_<guest vpid>:<guest process name>`. 【P0 + P2 cross-check】

**One topology error corrected**: `com.vphonegaga.titan` and `:instance1` have the **same** PPid
(both point to host zygote); they are **siblings**, not parent/child. The virtual kernel's parent is `:instance1`.

### 4.2 Privileges and scheduling — **Grade A / P0 / K1 observation + K2 mechanism**

| Observation | Value |
|---|---|
| Host-side UID of all guest processes | **10383** (app UID, no exceptions) |
| `CapEff` / `CapPrm` of all guest processes | `0000000000000000` |
| `NoNewPrivs` of all guest processes | `1` |
| `TracerPid` of all guest processes | **0** (⇒ **ptrace interception route ruled out**) |
| `Seccomp` of all guest processes | `2` |
| **`Seccomp_filters`** of all guest processes | **`2`** ← see §4.3 |
| Namespaces | `/proc/<pid>/ns/` contains only `cgroup` / `mnt` / `net`; **no `NSpid` field** ⇒ **no PID namespace**, and no UTS / IPC / USER / TIME 【**P1**】 |
| Mounts | Host mount table has **no product-specific mount point**; guest `mountinfo` matches the host app (~152 entries) 【P1】 |
| cgroup | Whole guest tree in `cpuset:/top-app`; its parent `instance1` in `/foreground` |
| `oom_score_adj` | `0` for the whole guest tree; `200` for `instance1` |

### 4.3 ★ The second seccomp filter — **Grade A / P0 / K1 (core evidence)**

The `Seccomp_filters` field in `/proc/<pid>/status` gives irrefutable layered evidence:

| Process | `Seccomp` | **`Seccomp_filters`** |
|---|---|---|
| Host `init` / `zygote64` | 0 | 0 |
| `com.vphonegaga.titan` | 2 | **1** |
| `com.vphonegaga.titan:instance1` | 2 | **1** |
| **`titan64_0:kernel`** | 2 | **2** ← transition point |
| **`titan32_0:kernel`** | 2 | **2** |
| **all guest processes** | 2 | **2** (100%) |

**Interpretation**:

- Android force-installs one seccomp filter per app process (installed by zygote), so the host side is always 1 layer.
- seccomp filters **can only be stacked, never removed**. The 1→2 jump happens after `:instance1` forks
  the virtual kernel and before guest code runs.
- ⇒ **Current evidence best supports "the 2nd layer is installed by the guest virtual kernel during
  bootstrap and inherited by all descendants"**; **the exact installing caller has not been directly observed**. **K2.**
- The host device **has no root, no Magisk, no Zygisk**, so this layer cannot come from the host.

⇒ **VPhoneGaGa's userspace syscall projection really exists; the implementation layer is seccomp.**
(The exact strategy — `RET_USER_NOTIF` / `RET_TRACE` / `RET_ERRNO` — requires reading the BPF program: **U / K3**.)

### 4.4 ★ `/proc` and identity-class syscalls projected wholesale — **Grade C / P2 vs P0 / K1**

With a guest-internal shell, the **same process** can be read from both sides:

| Observation | Guest view (P2) | Host-kernel truth (P0) | Verdict |
|---|---|---|---|
| `su -c id` | `uid=0(root) gid=0(root)` | uid **10383** | **projected/fabricated** |
| `CapEff` / `CapPrm` | `0000003fffffffff` (all caps) | `0000000000000000` | **projected/fabricated** |
| `Seccomp` | **0** | **2** (two filters) | **projected/fabricated** |
| `NoNewPrivs` | **0** | **1** | **projected/fabricated** |
| PID space | `init=1`, `magiskd=43`, `zygote64=62` | 7098 / 7227 / 7263 etc. | **virtual PID mapping** |
| `/proc` numeric dirs | 134 | 1112 | **filtered** |
| Real host PIDs visible | **No** | — | **filtered** |
| `/proc/version` | `4.14.42-titan (titan@ubuntu) gcc 4.8.4 …2019` | `5.15.167-android13-8-o-01144` | **projected/fabricated** |
| `/proc/cpuinfo` | `CPU part: 0x801` (Cortex-A53) × 8 | `0xd46/0xd47/0xd4d/0xd4e` | **projected/fabricated** |
| `/proc/meminfo` | `4,063,232 kB` | `15,496,684 kB` | **projected/fabricated** |
| `/proc/uptime` | ~5.75×10⁸ s (**≈18 years**, idle > uptime) | real value | **projected (broken)** |
| `/proc/self/maps` | `/system/lib64/libnetd_client.so`, dev `03:08`, ino `3080` | `…/androidfs_10.0.0/system/readonly.bin` | **path rewrite / display-layer projection** |
| `/proc/self/fd` | `0/1/2 -> sock:[782]` | real socket | **projected (malformed)** |
| `/proc/1/exe` mode | `lr--r--r--` | real procfs is always `lrwxrwxrwx` | **projection artifact** |
| `cgroup` | `2:cpu:/apps` / `1:cpuacct:/` (Android 10 layout) | 5 controllers + `/uid_10383/pid_…` | **projected/fabricated** |
| `/proc/mounts` | `/dev/block/platform/host/by-name/system` ext4 | no corresponding mount | **projected/fabricated** |
| `df /data` | 933 GB | 933 GB | **leaked (not disguised)** |
| SELinux context | `--  u:object_r:toolbox_exec:s0` (extra `--`) | — | **emulation artifact** |

**Key insight**: the filter projects `Seccomp` as `0` — **while intercepting/projecting this process's
syscalls, it tells the process "I do not exist".**

**P1 reinforcement (archived from the early comparison carrier)**:
- The host-side fd table contains hundreds of `memfd:titan-tmp-inode-N (deleted)` 【P1】.
  This only proves **a large number of anonymous/temporary memory objects are related to the userspace
  virtual-file implementation**; treating them as "the entities of all fake `/proc` files" is
  **beyond the evidence boundary**. **K2.**
- The string table of `libuserkernel64.so` contains `PR_SET_SECCOMP` / `PR_GET_SECCOMP` / `PTRACE_SEIZE` /
  `PTRACE_GETREGS` constants 【P1】, matching a seccomp-installation path.
- `/proc/<pid>/maps` (P1) shows the guest maps `…/androidfs_10.0.0/system/readonly.bin`,
  while `/proc/<pid>/fd` contains `memfd:titan-tmp-inode-N`.

> Note: what is directly proven here is "the same process yields different semantic results from the
> guest and host perspectives". Whether that arises from path-level hook+synthesis, a userspace VFS,
> seccomp user notification, or a mix is **K3**.

### 4.5 ★ Self-evident breakage of the projection — **Grade C / P2 / K1 (strongest evidence)**

**The same kernel state exposes different answers across interfaces:**

```text
$ cat /proc/self/mountinfo
28 26 3:8  / / ro,seclabel,barrier=1 shared:2 - ext4 /dev/block/platform/host/by-name/system rw,seclabel

$ cat /proc/mounts
/dev/block/platform/host/by-name/system / ext4 ro,seclabel,barrier=1 0 0

$ mount
/dev/block/mtdblock0 on / type ext4 (ro,seclabel,barrier=1)
                    ↑↑↑↑↑↑↑↑↑↑ a completely different device name
```

Other breakages:

| # | Breakage | Note |
|---|---|---|
| 1 | `/proc/mounts` and `mount` give different device names | two answers for one state ⇒ **matches an interface/path-level projection model** (K2) |
| 2 | `/proc/uptime` ≈ 5.75×10⁸ s (**18 years**), idle > uptime | struct-assembly error |
| 3 | `/proc/self/fd` shows `sock:[782]` | the kernel always uses `socket:[inode]` |
| 4 | `/proc/1/exe` mode `lr--r--r--` | real procfs `exe`/`cwd` is always `lrwxrwxrwx` |
| 5 | Device path `platform/**host**/by-name/system` | real platforms are `1d84000.ufshc` etc.; **`host` is the product's own naming** |
| 6 | `/share` mount source shows a host path | **host path leaked**: `/storage/emulated/0/Android/data/com.vphonegaga.titan/files/instance1/shared` |
| 7 | `/proc/net/dev`: lo/eth0/wlan0 have **identical** byte counts | three interfaces reuse one dataset |
| 8 | SELinux context `--  u:object_r:toolbox_exec:s0` | emulation-layer artifact |

⇒ **Proving the projection with the product's own bugs is stronger than any external inference.**
But "projection/fabrication" itself is K1; its concrete internal implementation remains K2/K3.

### 4.6 ★ Mount subsystem — a userspace virtual implementation (guest-side uid sweep) — **Grade C / P2 / K1**

#### 4.6.1 Guest-side uid sweep (the core experiment of this subsection)

**Design**: inside the guest, start the test program as root, `setuid` to a target uid, then call
`mount(tmpfs)`, observing the return value across uids. The program is raw-syscall
(`-nostdlib -static`); the target path is `/data/local/tmp/mu`.

| Target uid | actual `getuid()` | `mount(tmpfs)` | `umount` |
|---|---|---|---|
| 0 | 0 | ✅ ret=0 | ✅ ret=0 |
| 1000 | 1000 | ✅ **ret=0** | ❌ EPERM(1) |
| 2000 | 2000 | ✅ **ret=0** | ❌ EPERM(1) |
| 10000 | 10000 | ✅ **ret=0** | ❌ EPERM(1) |
| 10123 | 10123 | ✅ **ret=0** | ❌ EPERM(1) |

**Conclusion (K1, observable fact only)**:
> Inside the guest **any uid (including uid 10000 / 10123) can successfully `mount(tmpfs)`**;
> yet a real Linux kernel under any conventional configuration **cannot** let uid 10000 mount `tmpfs`
> (it requires `CAP_SYS_ADMIN`).
> ⟹ **the guest's `mount()` result cannot be explained by "the host kernel executing the same call
> under Linux permission rules".**
>
> Another K1 fact: **the mount permission is asymmetric** — `mount` is allowed for every uid while
> `umount` is allowed only for uid 0. That asymmetry itself cannot arise from a single kernel
> permission model.

**Candidate model (K2)**:
> The model best fitting the above is an **independent userspace mount-semantics handler** in the
> guest, whose permission table is defined by userspace code (`mount` open to all uids, `umount` root
> only) and which maintains a mount tree the host kernel VFS does not hold.

**Indistinguishable items (K3)**:
> Current experiments **cannot** prove "the host kernel is not involved at all". A chain such as
> "guest userspace layer → transform → some other host interface → host kernel" remains theoretically
> possible. What is proven is **that the result cannot be explained by "the host kernel directly
> executing under Linux permission rules"**, not "zero host-kernel involvement".

#### 4.6.2 Why the "host uid 2000 fails" observation is **not** used as a control (important methodology correction)

> ⚠️ **This subsection replaces earlier wording.** An earlier version treated "host uid 2000 gets
> `EACCES` vs guest uid 2000 gets `ret=0`" as a decisive controlled experiment. **That control is
> invalid**, for these reasons:

- The host's uid 2000 getting `EACCES` from `mount()` is the **necessary outcome of standard Linux
  permission checking** (no `CAP_SYS_ADMIN`), **unrelated to any projection layer**; it cannot serve
  as evidence that a projection layer exists.
- It only proves "**the permission models on the two sides differ**", and **not** "the guest's
  `mount()` cannot be executed by the host kernel directly" — because in that comparison the host
  kernel **was never allowed to execute** the call.
- Mistaking a **permission difference** for an **architecture difference** is a classic result
  confusion.

**No fair host-side control can be constructed in this environment** (measured):

| Control design | Measured result |
|---|---|
| Host root (P1) calls `mount()` | **Unavailable**: the primary carrier has no usable root path |
| Host `unshare -Urm` (user namespace), then `mount()` | **Unavailable**: `unshare: Invalid argument` (kernel/SELinux forbids unprivileged userns) |
| Host `unshare -m` (mount namespace), then `mount()` | **Unavailable**: `unshare: Operation not permitted` |

⇒ This report **explicitly states**: the host-side `mount` failure is **a reference observation only,
not projection-layer evidence**. What actually supports the conclusion is the uid sweep in §4.6.1
plus the four findings below (whitelist / host-invisible / interface mismatch / in-memory state).

#### 4.6.3 Capability boundary = `/proc/filesystems` whitelist

| Guest `/proc/filesystems` | Mount result |
|---|---|
| rootfs / proc / tmpfs / devpts / selinuxfs | ✅ ret=0 |
| socketfs / sdcardfs | ❌ needs special conditions |
| **anything outside the list** (ext2/3/4, f2fs, btrfs, overlay, squashfs, cgroup2, ramfs, debugfs, tracefs…) | ❌ **EINVAL(22)** |

The host `/proc/filesystems` has 30+ entries; the guest has only 7.
⇒ **the `mount` implementation checks a hard-coded whitelist.**

#### 4.6.4 Semantic fidelity (partial implementation)

| Feature | Behavior |
|---|---|
| `-o ro` | ✅ **truly enforced** (write ⇒ `EROFS`) |
| `-o remount,rw` | ✅ works |
| `-o noexec,nosuid,nodev` | ✅ recorded and effective |
| `-o mode=0755,uid=1000,gid=1000` | ⚠️ **only written into `/proc/mounts` text; the actual dir stays 777 root:root** (not enforced) |
| Non-existent mount point | ❌ `ENOENT` |
| `--move` | ❌ `EINVAL` (unimplemented) |
| `--bind` | ✅ `ret=0` |
| `df` on virtual mounts | **invisible** (no statfs response) |

#### 4.6.5 Completely invisible on the host (K1)

- After the guest mounts, **host `/proc/mounts` gains nothing**.
- Host mount table ~194 entries; guest mount table ~48–49 entries, **no overlapping product-specific mount point**.
- Host-side grep `vphonegaga|instance1|readonly` = **empty**.

**Conclusion**:
> **"Host mount table shows nothing ⇒ no mount capability" is an invalid black-box inference.**
> Measured: the guest's `mount()` result **cannot be explained by the host kernel executing the same
> call under Linux permission rules** (K1); the host kernel mount table does not hold these mounts (K1);
> the model best fitting the observations is a **userspace mount tree** in the guest (K2); capability
> is whitelist-bounded and options like `mode/uid/gid` are not enforced (K1).

#### 4.6.6 Valid-evidence list for this section (excluding the invalid control)

The **valid** evidence supporting "mounts are a userspace virtual implementation" comprises 5 items,
**none of which depend on the "host EACCES" comparison**:

| # | Valid evidence | Where | Level |
|---|---|---|---|
| 1 | Inside the guest **any uid (incl. 10000) can successfully `mount(tmpfs)`**, impossible on real Linux | §4.6.1 | K1 |
| 2 | Mount permission is **asymmetric**: `mount` open to all uids, `umount` root-only | §4.6.1 | K1 |
| 3 | `/proc/filesystems` whitelist has only 7 entries; anything outside returns `EINVAL`; host has 30+ | §4.6.3 | K1 |
| 4 | Host mount table never changes; `/proc/mounts` and `mount` give different device names | §4.6.5 / §4.5 | K1 |
| 5 | `bind mount` broke `/system`; recovery after instance restart ⇒ mount state is **userspace in-memory** | §10.2 | K1 |

> ❌ **Not used as evidence**: the host's uid 2000 `EACCES` (reference only); host `mount ext4`
> `EACCES` vs guest `EINVAL` (permission vs format — not comparable); `umount` returning `EPERM` on
> both sides (only proves both refuse, not symmetry). See §4.6.2.

### 4.7 ★ Network subsystem — a hybrid model (controlled experiment) — **Grade C / P2 / K1**

#### 4.7.1 Sockets are real host sockets (K1)

A listening socket was created inside the guest (port 4660 / `0x1234`), then queried on the host:

```text
host /proc/net/tcp:
   5: 00000000:1234 00000000:0000 0A … uid=10383 inode=11636144   ← real!
guest internal /proc/net/tcp:  (empty, projected away)
```

⇒ **the guest's socket is a real host-kernel socket** (uid shows the app's real uid 10383).
⇒ the network namespace is **shared with the host** (host reading the virtual kernel's
`/proc/<pid>/net/tcp` ≈ host global connection count).

#### 4.7.2 But `setsockopt` is intercepted by userspace (controlled experiment, K1)

| Socket option | Host (real 5.15) | Guest (projection) |
|---|---|---|
| IP_TOS(1) / IP_TTL(2) / IP_MTU_DISCOVER(10) | ✅ | ✅ same |
| **IP_RETOPTS(7)** | ✅ 0 | ❌ **EINVAL** |
| **IP_PKTINFO(8)** | ✅ 0 | ❌ **EINVAL** |
| **IP_RECVTTL(12)** | ✅ 0 | ❌ **EINVAL** |
| SO_REUSEADDR / SO_KEEPALIVE / SO_RCVBUF | ✅ | ✅ same |
| TCP_NODELAY / TCP_KEEPIDLE | ✅ | ✅ same |
| **UDP IP_RECVTTL / IP_PKTINFO** | ✅ 0 | ❌ **EINVAL** |

⇒ The host kernel accepts these options; the guest refuses ⇒ **`setsockopt` is intercepted by a
userspace layer that only lets a whitelisted subset through.**

#### 4.7.3 Corroborating symptoms

- `ping` inside the guest: `setsockopt(IP_RECVTTL): Invalid argument`, and replies show **`ttl=0`** (abnormal).
- Guest internal `/proc/net/tcp` and `/proc/net/tcp6` are **empty**; `/proc/net/sockstat` **does not exist**.
- The guest's `/proc/net/unix` contains **no** `@titan-pipe-*` (the host side shows ~38).

#### 4.7.4 Conclusion

> Networking is **neither purely "reusing the host stack" nor purely "a userspace stack"**, but a **hybrid**:
> - **data plane (K1 fact)**: a socket created in the guest **exists in the host kernel** (visible in host `/proc/net/tcp`, uid=10383);
> - **control plane (K1 fact)**: some `setsockopt` options are **intercepted by a userspace layer** with a whitelist;
> - **info plane (K1 fact)**: `/proc/net/*` is **projected/filtered**, hiding real connections.
>
> **Candidate model (K2)**: data-plane transport is very likely handled by the host kernel stack.
> **Indistinguishable items (K3)**: whether additional userspace processing sits above the data plane
> cannot be decided by current experiments.
>
> "It can reach the network ⇒ it reuses the host stack" overclaims; the correct statement is "a
> corresponding socket **exists** in the host kernel, but there is userspace involvement on the socket
> control plane, and real connections are not visible inside the guest".

### 4.8 Hardware proxy bus `@titan-pipe-*` — **Grade A / P0 / K1 name enumeration**

Host `/proc/net/unix` is fully readable by the shell identity and exposes the IPC channel names
between guest subsystems and the host:

```text
@titan-pipe-1-framebuffer      @titan-pipe-1-input-qwerty     @titan-pipe-1-activity
@titan-pipe-1-gsm              @titan-pipe-1-gps              @titan-pipe-1-network
@titan-pipe-1-camera           @titan-pipe-1-sensors          @titan-pipe-1-fingerprint
@titan-pipe-1-crash            @titan-pipe-1-hw-control       @titan-pipe-1-ipc
@titan-process-worker-server-1-<host PID>   × 95
@titan-1-process-monitor
```

- The above is a raw name enumeration from `/proc/net/unix`. **No network or communication
  architecture is inferred from it.**
- The guest's internal `/proc/net/unix` **cannot see** these names (~38 → 0): IPC names are hidden from the guest.
- ⇒ **this naming reveals the existence of proxy channels for guest peripherals**: camera / GPS /
  telephony / sensors / fingerprint / graphics / input / Activity each have their own abstract unix
  socket channel. The guest also exposes product-specific properties
  `android.host.adb.port=6556`, `android.host.adb.server.port=6038`. 【P2】

### 4.9 Storage layer — **Grade B / P1 observation + K2 interpretation**

> This section describes **structure only**; byte-level format details are forensics, not architecture.

- The guest image is **not mounted through the kernel**; the host-side runtime carries it in a **private
  container format** characterized by:
  - **unencrypted**: guest processes can **read-map** it directly, and mapped pages are shared among them;
  - **volume-based**: each partition consists of a read-only data volume plus an index/superblock;
  - plus a **writable layer and a cache layer** for run-time writes.
- **The guest's block devices and filesystems are projected**: e.g. `/proc/mounts` shows an ext4 block
  device, but the host kernel mount table has no corresponding entity (§4.6.5).
- The container also includes a **parseable Android boot partition**, i.e. the boot partition the guest
  sees is provided by the container. **K1.**

### 4.10 Virtual root and Magisk — **Grade C / P2 / K1 form observation + K2 mechanism**

Measured inside the guest:

```text
$ su -c id
uid=0(root) gid=0(root) groups=0(root) context=--  u:object_r:toolbox_exec:s0

$ magisk -v        →  26.0:MAGISK:R
$ magisk -V        →  26000
$ ls -l /sbin/magiskinit  →  -rwxr-x--- 1 root root 642952
$ ls -l /sbin/su          →  /sbin/su -> ./magisk
```

**Correction on the source of root (this version)**:

> An earlier version stated "guest root is a **Magisk 26.0 stack** running inside the app UID".
> The four-state comparison (§4.14) shows this is **not accurate**:
>
> **The product ships its own `su` authorization mechanism** (started directly by the guest `init`,
> **present in all four states**: Magisk on / off / boot reset / nothing installed), and that `su`
> **has its own toggle** managed by the product; **Magisk is an optional layer**.

**Conclusion**:

- The product's root channel is its **own `su`**, independent of Magisk; the Magisk toggle only affects
  Magisk's own boot chain.
- The external reason it works: the 2nd seccomp filter/projection layer projects the return values
  of `getuid` / `getresuid` / `capget` to `0` / all capabilities.
  **Host-kernel measurement of the same process: uid=10383, CapEff=0 (P0).**
- The host device **has no usable root path**, so guest root cannot be a host privilege escalation.
- Magisk form: `26.0:MAGISK:R`. ⚠️ No hash comparison against an official build was performed, so
  "unmodified official build" cannot be asserted. **K1 form / K3 provenance.**

### 4.14 Magisk-layer injection mechanism, four-state comparison, and version compatibility range — **Grade C / P2 / K1 observation + K2/K3 inference**

> This section is based on four host-side process captures (`process_log*.txt`,
> `ps -ef | grep titan` polled every 0.3 s).

#### 4.14.1 Four-state comparison

| State | Magisk-related processes | Components | `netd` vpid | boot chain after apexd |
|---|---|:---:|:---:|---|
| **Magisk ON** | `magisk`(magiskinit)+`magiskd`×4+`busybox`+`sh`×6+`lspd`+`zygiskd`×2 | 117 | **60** | apexd → **magisk→magiskd→busybox→sh→lspd** → netd |
| **Magisk OFF (boot not reset)** | `magiskd`×2+`lspd`+`zygiskd`×2+`resetprop` (**residual**) | 115 | **60** | apexd → **magiskd→app_process** → netd |
| **Boot reset** | **0** | 102 | **42** | apexd → **netd** |
| **Boot on, nothing installed** | **0** | 96 | **42** | apexd → **netd** |

**K1 observable facts**:

1. **"Boot reset" and "nothing installed" are the same clean state** — their vpid layout matches
   item by item (`ueventd`=4, `logd`=14, `vold`=23, `netd`=42, `zygote64`=43, `zygote`=44).
2. **The Magisk layer's insertion point is fixed**: always **after apexd, before netd**.
3. **vpid numbering shifts as a whole with Magisk injection**: `netd` 60↔42, `zygote64` 61↔43,
   `zygote` 62↔44 (Magisk inserts ~18 processes).
4. **The product's own `su` is present in all four states** (started by `init`, with its own toggle).
5. **When boot is not reset, the residual Magisk patch still sideloads `magiskd`**
   (its parent is the virtual kernel, not init).

#### 4.14.2 Injection mechanism (candidate model, K2)

> The model best fitting the observations is:
> **the product does not run the "standard Magisk install flow"; it parses the Magisk payload inside
> the boot image and launches `magiskd` directly through its own compatibility implementation.**

Supporting observations:

| Observation | Why it supports the model |
|---|---|
| `magiskinit` (vpid 42) is a child of the **guest init** | not the standard boot flow's PID-1 takeover |
| The Magisk phase is fixed between apexd and netd | a **chosen injection point**, not native Android order |
| The product ships its own `su` with its own toggle | the root channel is self-built; Magisk is only an overlay |
| With boot not reset, `magiskd` is sideloaded by the **virtual kernel** | the product parses/starts it actively, not via the full install chain |

#### 4.14.3 Version compatibility range (K3 / unconfirmed)

- The Magisk version measured here is **26.0** (`26.0:MAGISK:R`).
- Empirical observation (operator): the product has a **compatibility range** for Magisk versions;
  higher versions may fail to launch Magisk or even fail to boot the guest.
- ⚠️ **The exact supported versions are unconfirmed**: the operator tested several versions earlier
  but **kept no record**; this report measured only **26.0**.
- Therefore it **must not be written as "compatible with 26.0 only" or "locked to one version"**.
  The accurate statement is: **compatibility is version-dependent, with unknown boundaries (K3)**.

### 4.11 Scheduling priority — **Grade A / P0 / K1 observation + K2 mechanism**

Controlled experiment (backgrounding the VM, then restoring):

| | `instance1` | whole guest tree |
|---|---|---|
| before HOME | `cpuset:/top-app` | `cpuset:/top-app` (100%) |
| after HOME | `cpuset:/foreground` | `cpuset:/top-app` (none dropped) |
| `oom_score_adj` | `200` | `0` |

⇒ **Mechanism that best fits the observation (K2)**: guest processes **inherited the cgroup bucket and
`oom_score_adj` at the moment they were forked from `instance1` during VM startup**; afterwards any
host demotion of `instance1` no longer affects already-forked guest processes.

> ⚠️ **"Permanent" cannot be inferred.** This experiment covers only a ~6-second window after one
> HOME switch. Marked **U / K3**.

### 4.12 Graphics stack — **Grade B / P1 / K1 mapping observation + K3 implementation**

`kgsl / ion / dmabuf` is the default path for **any** GPU-rendering process on Android.
Externally, the guest SF holds host paths such as `/dev/kgsl-3d0`; whether this is full passthrough,
proxy forwarding, or userspace relaying cannot be uniquely determined by black-box means. **K3.**
What is genuinely worth recording is the `@titan-pipe-*` channel naming in §4.8.

### 4.13 In-process ELF loading — **Grade B / P1 / K1 observation**

- Guest processes are **not started via ordinary `exec`**: an **in-process ELF loader** maps the guest
  executable **into the current process, relocates it, and jumps into its entry point**.
- Cross-check (P0): the `Name` field in `/proc/<pid>/status` is that loader for every guest process,
  while the host-side process name (`titan{32,64}_<vpid>:<name>`) is maintained separately by the runtime.
- The loader ships inside the APK under a `.so` name and runs via the executable bit granted at install
  time — i.e. **an app's own code can be executed without extra privileges**.

---

## 5. Architecture Model

### 5.1 The essence: three externally observable processing paths

**This is the single most important section for understanding the product.**

> **Terminology (important)**: A / B / C describe **"processing results and semantic paths of a
> request / object access"**, **not "three confirmed internal implementation branches"**, and
> **not "syscall types"**.
>
> An object like `/proc/cpuinfo` is accessed through several syscalls (`openat()` → `read()`):
> the external result of `openat` may appear as path C, that of `read` as path B.

Every **request / object access** by the guest falls, in externally observable behavior, into:

| Path | Externally observable semantics | Reaches host kernel | Typical requests | Determinacy |
|---|---|---|---|---|
| **A · host-capability reuse / passthrough** | Behavior matches host Linux semantics | cannot be uniquely determined | `mmap`, `futex`, `nanosleep`, `clock_gettime`, socket data plane | **K2** |
| **B · synthesis / projection** | Return value or content constructed guest-side | external result does **not** use the host's real semantics | `getuid`/`getpid`/`capget`; `uname`/`sysinfo`; `/proc/{status,cpuinfo,meminfo,version,uptime}` | **K1 result + K3 mechanism** |
| **C · redirection / virtual filesystem** | Object lands in the guest's own storage/namespace | real mmap/page-cache semantics observable externally | `openat("/system/…")`, `stat`, `mount`, `/proc/<pid>/maps` display layer | **K1 result + K2/K3 mechanism** |

**This version explicitly classifies mounts and the network control plane as involving "userspace semantic handling the host kernel cannot directly explain" (K1).**

### 5.2 Syscall projection comparison table (core evidence of this version)

Summary of the same binary run on both sides:

| Semantic class | Comparison result | Level |
|---|---|---|
| `uname()` / `sysinfo()` | guest returns synthesized values (kernel, RAM, proc count) | **K1 projected** |
| `getuid/geteuid/getgid` | guest returns per virtual uid | **K1 projected** |
| `clock_gettime(REALTIME)` | both sides **identical** seconds | **K1 passthrough** |
| `mount/umount` | guest-side uid 10000 can still `mount(tmpfs)`; `umount` is root-only | **K1 userspace** |
| `setsockopt(IPPROTO_IP)` | host OK vs guest EINVAL | **K1 intercepted** |
| `socket/bind/listen` | guest's socket appears in host `/proc/net/tcp` | **K1 passthrough** |
| `/proc/*` content | systematically different from host truth | **K1 projected** |

### 5.3 Layered view (with determinacy tags)

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Host Linux kernel 5.15.167 (real)                                    │
│   real syscalls · real procfs · real sockets · real GPU · real VMA   │
└─────────────────────────────────────────────────────────────────────┘
      ▲  ① externally appears as host-capability path; whether it truly
      │     enters the host kernel is K3
┌─────┴───────────────────────────────────────────────────────────────┐
│ L0  2nd seccomp filter (installed by the guest virtual kernel;       │
│     inherited by the whole tree)                                     │
│     → intercepts/projects specific openat/read paths                 │
├─────────────────────────────────────────────────────────────────────┤
│ L1  userspace kernel layer  libuserkernel64.so (zero exported syms)  │
│     · userspace VFS object model (vma/dentry/inode/file)             │
│     · virtual PID / UID / capability mapping                         │
│     · userspace mount tree (independent of host VFS) ★measured       │
│     · socket control-plane whitelist (setsockopt interception) ★     │
│     · /proc content synthesis (→ memfd:titan-tmp-inode-N)            │
│     · @titan-pipe-* peripheral proxy channels                         │
├─────────────────────────────────────────────────────────────────────┤
│ L2  in-process ELF loader  libloader64.so / libloader32.so           │
│     · mmap guest ELF from readonly.bin by offset and self-relocate   │
├─────────────────────────────────────────────────────────────────────┤
│ L3  guest Android 10 stack (~85–100 processes)                       │
│     init / zygote64+32 / system_server / surfaceflinger /           │
│     adbd(6556) / Magisk 26.0 / LSPosed / Zygisk64+32                │
├─────────────────────────────────────────────────────────────────────┤
│ L4  storage: private plaintext container (not mounted, not encrypted)│
│     private plaintext container (unmounted · mappable · volume-based) │
├─────────────────────────────────────────────────────────────────────┤
│ L5  host presentation: single Activity + host SurfaceFlinger          │
└─────────────────────────────────────────────────────────────────────┘
```

> L0/L1 "interception/projection" is a **K1 observable result** (including controlled experiments);
> "userspace kernel layer" is a **K2 candidate explanation**; its concrete internal implementation is **K3**.

### 5.4 Positioning vs gVisor (complexity should not be compared directly)

| Dimension | gVisor (true LibOS) | VPhoneGaGa 3.4.0 |
|---|---|---|
| Syscall handling | **all** intercepted, **all** semantics reimplemented in userspace | **external semantics split**: A passthrough / B synthesis / C redirection + mounts & network control plane decided in userspace |
| Memory management | own address-space abstraction and page tables | **externally reuses host VMA + mmap semantics** |
| CPU scheduling | both use host CFS externally | same |
| Process isolation | full sandbox | **no namespace at all, same uid (K1)** |
| Networking | own userspace stack | **real host sockets + control-plane proxy + /proc projection (K1)** |
| What the guest "sees" | an independent kernel abstraction implemented by sentry | a **per-path synthesized projection (K1 result)** |
| Essence | **"I built a kernel"** | externally, **"I acted out a kernel"**; identity / mounts / network control plane all involve **userspace semantic handling that the host kernel cannot directly explain** |
| Core engineering | kernel semantic completeness (network stack / memory / filesystem all self-built) | **correctness of the cross-process semantic shim** (see §5.5); `/proc` field consistency + Magisk compatibility + device adaptation are the concrete grind on top of it |

### 5.5 Where the real engineering effort is: the cross-process semantic shim runtime

> This section corrects the earlier claim that the "field-by-field grind" was the main difficulty.
> That grind exists, but it is **surface-level**; the real difficulty is the **architectural multi-process semantic shim**.

#### 5.5.1 Topology comparison with conventional architectures

| Architecture | Process topology | syscall handling | Who maintains context |
|---|---|---|---|
| QEMU / KVM | **1 main process** + N vCPU threads | vCPU traps → VMM | VMM owns the address space; simple |
| gVisor | **1 sentry process** | traps into sentry, reimplemented in Go | sentry owns it; simple |
| LXC / Docker | N host processes | **straight to host kernel** (with ns/cap) | the kernel; no shim |
| proot / ptrace | N host processes | ptrace interception, **still calls real syscalls** (path rewrite only) | kernel + tracer |
| **This product** | **N host processes + in-process shim + central broker** | in-process shim captures → **IPC** → broker decides semantics, **without calling privileged syscalls** | **broker, distributed across processes** |

**The conventional intuition is "one main process holds the whole guest." This product does the opposite: it splits one guest into a hundred-plus host processes.** That is its special point.

#### 5.5.2 The difficulties, one by one

1. **One ledger must be shared across processes**
   Virtual PID / UID / capability / cwd / fd table / mount view / mm context all live **in a single address
   space** in a VM or sentry; here they must sit in the broker and be referenced by every carrier process
   over IPC. **State is not local — it is one hop away.**

2. **"It does not even call for permission" — the most critical difference**
   It **does not enter the kernel for privileges at all**: the privileged calls `mount` / `setuid` / `capset`
   **never happen**.
   - So **giving it root or debug privileges is useless** — it never issues that privileged syscall;
   - permission decisions are made entirely by the broker's own policy table;
   - this is exactly why "**uid 10000 can mount, and mount/umount are asymmetric**" (§4.6.1).
   ⇒ Things that a real system solves by "just calling the kernel" must here be **fully re-implemented in software**.

3. **Every syscall may cross a process boundary**
   One call = argument capture → serialization → IPC → broker decision → return → register write-back.
   This requires handling concurrency, ordering, timeouts, back-pressure, and message cleanup.
   ⇒ Effectively **building a distributed RPC system without kernel help, while appearing as a single-machine kernel**.

4. **Process lifecycle must be mirrored**
   `fork` / `exec` / `exit` / task-death must be reflected in both the carrier process and the broker;
   this involves orphan reaping, subreaper semantics, and context lifecycle synchronization.

5. **Offload the heavy lifting to the host OS**
   Scheduling (CFS), page cache, `mmap` / VMA, GPU, real sockets — these are **not reimplemented, but borrowed**.
   This is the **precondition** for running inside an app sandbox, and what "a portion of the computation is
   fully offloaded to the operating system" means.

6. **The price: two-ledger consistency**
   Some semantics come from host-kernel truth, others are userspace simulations, and the two must still look
   consistent.
   ⇒ This is exactly the source of the `/proc` vs `mount` contradiction and the `/proc/net/*` vs real-socket mismatch.

#### 5.5.3 In one sentence

> It **simulates a single-process LibOS using a multi-process topology plus a full semantic shim**, while
> delegating the expensive data plane to the host kernel.
> The difficulty is not interception itself, but:
> **making a hundred-plus host processes appear externally as one consistent Android device, without kernel
> help in maintaining context.**
> This also explains why it is not something a conventional project can easily produce.
>
> The engineering-side **reproduction roadmap and shim design (including high-performance design)** is in [`复现路线与垫片设计.md`](复现路线与垫片设计.md) (Chinese).

### 5.6 Minimal architecture model (compressed skeleton)

Compressing everything that has K1 support yields the following minimal model — enough to answer
"if one wanted to build something similar, what would it take?":

```text
                    ┌──────────────────────────────┐
                    │   Guest semantic projection   │
                    │   (userspace semantic layer)  │
                    └──────────────┬───────────────┘
        ┌──────────────────────────┼──────────────────────────┐
        ▼                          ▼                          ▼
  synthetic semantics       virtual objects            host-backed
  (userspace synthesis)     (userspace-maintained)      (host-carried)
        │                          │                          │
  · PID / UID / capability   · /proc view                 · real socket
  · uname / sysinfo          · mount tree                 · mmap / VMA
  · parts of /proc           · Android FS view            · clock
                             · virtual device state       · GPU fd
                                                           · host IPC buffers
        └──────────────────────────┼──────────────────────────┘
                                   ▼
                              Host Linux kernel
```

**Meaning of the three columns** (corresponding to the A/B/C paths in §5.1):

| Column | Semantics | Path | Determinacy |
|---|---|---|---|
| **synthetic semantics** | synthesized guest-side; no corresponding host truth | B | K1 result |
| **virtual objects** | state maintained in userspace; host kernel does not hold it | B / C | K1 result |
| **host-backed** | external behavior reuses host-kernel capability | A | K1 object exists / K2 processing location |

**Peripheral IPC** (`@titan-pipe-*`: framebuffer / input / camera / GPS / sensors / fingerprint…)
is the right-hand extension of this model: guest peripherals are uniformly proxied by the host via
abstract unix sockets.

**Engineering positioning derived from it**:

> Not "write an Android emulator", but
> **"build an Android userspace execution environment running under an ordinary Android app UID,
> add a sufficiently complete Linux/Android semantic projection layer,
> and route back to the host whatever cannot or need not be virtualized."**

**⚠️ Nature of this model**: the three columns classify **facts that already have K1 support**; they
are not assertions about internal implementation branches. The real implementation inside each column
remains K2/K3.

---

## 6. System Boot Flow (observation + inference)

1. **Host instance bootstrap** — host zygote forks `:instance1`; it loads `libVPhoneGaGaLib.so`,
   establishes the JNI channel and opens the instance's **private container volumes**.
2. **Virtual-kernel initialization** — `:instance1` forks `titan64_0:kernel`; that process
   **installs the 2nd seccomp filter for itself**; it parses the **container index**,
   builds a userspace VFS, and sets up the virtual mount tree.
3. **Syscall virtualization online** — every process forked afterwards inherits the seccomp filter and
   enters the "guest" semantic space: PID / UID / capability / `/proc` / mounts / network control plane
   are all projected.
4. **Privileged process incubation** — after the guest init is started by the virtual kernel,
   `magiskd` / `lspd` / `zygiskd64` / `zygiskd32` appear, all with the **virtual kernel as their real
   host-side parent**.
   **Mechanism undetermined**: could be direct incubation, or `PR_SET_CHILD_SUBREAPER` re-parenting. **K3.**
   Meanwhile the guest side is projected a "real-device-shaped" logical parent tree.
5. **System services and graphics** — `titan64_1:init` parses `init.rc` and starts ~70 services;
   the guest SurfaceFlinger hands composited output to the host single Activity via `@titan-pipe-1-framebuffer`.
6. **Guest adbd** — listens on 6556 (`android.host.adb.port=6556`), providing the internal debugging entry point.

---

## 7. Corrections

This section proactively lists **overturned or corrected judgments**, including errors made by this
report's own AI-assisted analysis.

| # | Earlier conclusion | Current verdict | Basis | Level |
|---|---|---|---|---|
| 1 | "Host mount table shows nothing ⇒ no mount capability" | **overturned** | guest uid 10000 can still `mount(tmpfs)` + `/proc/filesystems` whitelist + host mount table unchanged | P0+P2 |
| 2 | "Can reach network ⇒ reuses host stack" | **corrected (hybrid)** | real host sockets + `setsockopt` intercepted + `/proc/net/*` projected | P0+P2 |
| 3 | "Simple library hijack, syscalls handled in place" | **corrected** | cross-component IPC + userspace VFS + mount tree + socket control plane | P0+P2 |
| 4 | "Host cannot see it ⇒ the function does not exist" | **overturned (paradigm error)** | the guest builds OS semantics in userspace; the host is inherently blind to them | — |
| 5 | "Hijacks all guest SVC trap instructions" | **corrected** | interception is at the **seccomp layer**, not SVC-instruction level; also not ptrace (`TracerPid=0`) | P0 |
| 6 | "Purely userspace root state machine" | **corrected** | it actually runs a **Magisk 26.0 stack** | P2 |
| 7 | "Four nested **independent** process trees" | **corrected** | no PID/UTS/USER/IPC namespace, same uid; "independent" does not hold | P0 |
| 8 | "host App → virtual kernel" parent/child relation | **corrected** | they are **siblings** under host zygote; virtual kernel's parent is `:instance1` | P0 |
| 9 | "The image is encrypted and only decrypted in memory" | **overturned** | guest processes can read-map the container directly; mapped content is plaintext | P1 |
| 10 | "Complexity far exceeds gVisor" | **does not hold** | different routes, not directly comparable | — |
| 11 | **new** "A/B/C are three internal implementation branches" | **redefined** | changed to "three externally observable processing results / semantic paths" | K2+K3 |
| 12 | **new** "networking is out of scope" | **upgraded to measured** | controlled experiments yield data-plane / control-plane / info-plane conclusions | P0+P2 |
| 13 | **new** "mount capability undetermined (U)" | **upgraded to K1** | controlled experiment directly proves userspace decision | P0+P2 |

### 7.1 Controlled-experiment upgrade list

| Conclusion | v1.1 status | v2.0 status | Upgrade basis |
|---|---|---|---|
| Mounts are a userspace implementation | U / K3 | **K1** | guest uid 10000 can still `mount(tmpfs)` (impossible on real Linux) |
| Mount capability boundary | untested | **K1** | `/proc/filesystems` whitelist + per-item mount tests |
| `uname`/`sysinfo` projection | C-grade side comparison | **K1** | raw-syscall controlled experiment |
| Network data plane reuses host | U / K3 | **K1 (real socket)** | guest listening port appears in host `/proc/net/tcp` |
| Network control plane intercepted | untested | **K1** | `setsockopt` two-sided comparison |
| `/proc/net/*` projected | untested | **K1** | guest internal empty, host side populated |

### 7.2 Tightened wording (academic norms)

| # | Original phrasing (too strong) | Changed to | Reason |
|---|---|---|---|
| 1 | "the 2nd layer is **only** installed by the virtual kernel" | "**current evidence best supports** installation by the virtual kernel at bootstrap" | temporal/topological correlation ≠ causal proof |
| 2 | "the memfds **are** the entities of the fake /proc files" | "**matches the above model well**" | beyond the evidence boundary |
| 3 | "**is not** a LibOS" | "**available observation does not support** classifying it as a complete LibOS" | universal negatives cannot be proven |
| 4 | "**three syscall** branches" | "**three request-handling paths**" | one access involves `openat`+`read`, different paths |
| 5 | "**performance is near-native**" | "has a **structural behavior** of reusing host-kernel paths" | this report **performs no performance measurement** |
| 6 | "targetSdk=29 is a **precondition**" | "is **one important compatibility condition** of the current route" | no controlled experiment done |
| 7 | "the guest's `mount()` **is decided entirely by userspace code, independent of the host kernel**" | "the final semantic result **cannot be explained by the host kernel directly executing the same call**; an independent userspace handler exists" | a "userspace → other host interface" chain cannot be excluded |
| 8 | "the socket data plane **is handled by the host kernel**" | "a corresponding socket object **exists** in the host kernel; the data-plane processing location is a **candidate model**" | object existence ≠ unique processing path |
| 9 | "the guest `/proc` **is synthesized by some hooked function**" | "the guest `/proc` output **systematically differs** from host truth" | proves different results, not the synthesis mechanism |
| 10 | "host mount table shows nothing ⇒ no mount capability" | "the final semantic result of guest mounts **cannot be explained by the host kernel directly executing the same call**" | independent userspace handling exists |

> **Review principle**: numbers, commands, raw output untouched; **only "already proven" statements are
> downgraded to "best supported by current evidence" or "black-box indistinguishable"**.

---

## 8. Research Limitations

| # | Limitation | Level |
|---|---|---|
| 1 | The exact 2nd-layer seccomp strategy is undetermined (requires reading the BPF program, kernel-space info) | **U / K3** |
| 2 | The primary host carrier has no P1; P1 observations come from an **early comparison carrier (archived)** and were not reproduced on the current carrier | — |
| 3 | The guest instance **may not be factory-fresh** | — |
| 4 | Guest kernel version, CPU model, and RAM are **disguised values**, unusable for hardware inference | — |
| 5 | The semantics of some `readonly.bin` header fields are unparsed | **U / K3** |
| 6 | **This report performs no performance measurement** (no syscall latency / `mmap` / `fork` / GPU benchmark) | **U / K3** |
| 7 | Network conclusions are limited to the **socket control plane**; **routing, DNS, VPN paths unanalyzed** (host may have a global VPN) | **U / K3** |
| 8 | Mount-tree internal data structures and IPC message format are unparsed | **U / K3** |
| 9 | Whether guest scheduling ownership changes over long periods or after process restarts is **observed only in one ~6-second window** | **U / K3** |
| 10 | No hash comparison of the guest Magisk binary against an official build | **U / K3** |
| 11 | The **complete field set** of guest `/proc` projection is unknown | **U / K3** |
| 12 | **During forensics, one `bind mount /system` broke the guest `/system` projection; recovered after restarting the instance** (see §10.2) | — |

---

## 9. Reproducible Commands

> Each block is tagged with the required permission tier.

```bash
H=emulator-5554       # host (unrooted), or 127.0.0.1:5555
G=127.0.0.1:6556      # guest (tap "Allow USB debugging" in the VM window)

# ═══════════ P0: host side (reproducible without root) ═══════════

# ── software version ──
adb -s $H shell dumpsys package com.vphonegaga.titan | grep -E 'versionName|versionCode|targetSdk'

# ── process topology ──
adb -s $H shell ps -A -o PID,PPID,USER,NAME | grep -E 'titan(32|64)_'

# ── ★ seccomp layering (core evidence) ──
adb -s $H shell 'for p in $(ps -A -o PID,NAME|grep -E "titan(32|64)_"|awk "{print \$1}"); \
  do awk "/^Seccomp_filters/{print}" /proc/$p/status; done' | sort | uniq -c
# expected: Seccomp = 2 for all; Seccomp_filters = 2 for all (host app = 1)

# ── ★ IPC channel enumeration ──
adb -s $H shell cat /proc/net/unix | grep -oE '@titan-pipe-1-[a-zA-Z0-9:=]*' | sort -u
adb -s $H shell cat /proc/net/unix | grep -c '@titan-process-worker-server'


# ═══════════ P2: guest-internal shell ═══════════

# ── two-sided comparison (same process, two views) ──
adb -s $G shell 'su -c id'
adb -s $G shell 'cat /proc/self/status | grep -E "Uid|CapEff|Seccomp|NoNewPrivs"'
adb -s $G shell 'grep CPU /proc/cpuinfo | head -3; grep MemTotal /proc/meminfo; cat /proc/uptime; cat /proc/version'

# ── self-evident fabrication: one state, multiple answers ──
adb -s $G shell 'head -2 /proc/self/mountinfo; head -2 /proc/mounts; mount | head -2'

# ── ★ mount capability: guest-side uid sweep (valid experiment) ──
# launch as root in the guest, setuid to target uid, then mount
# measured: uid 0/1000/2000/10000/10123 all succeed at mount(tmpfs); umount succeeds only for uid 0
adb -s $G push mntuid /data/local/tmp/
for u in 0 2000 10000; do adb -s $G shell "su -c '/data/local/tmp/mntuid $u'"; done
# whitelist: guest /proc/filesystems has only 7 entries
adb -s $G shell cat /proc/filesystems
# note: the host-side EACCES is a reference only, not evidence (no host root, no userns allowed)

# ── ★ network controlled experiment ──
# create a listening socket in the guest, query from the host
adb -s $G shell 'toybox nc -l -p 4660 &'
adb -s $H shell "cat /proc/net/tcp | grep -i '1234'"       # should appear, uid=10383
adb -s $G shell "cat /proc/net/tcp"                        # should be empty (projected)

# ── guest root form ──
adb -s $G shell 'magisk -v; magisk -V; ls -l /sbin/magiskinit'
```

---

## 10. Problems, Incidents, and Corrections Encountered During Forensics (honest record)

This section records, in full, the **problems encountered, mistakes made, and earlier writings that
were overturned** during this round of forensics. The purpose is not a disclaimer but to preserve
credibility: **it is normal for a retrospective report to contain errors; what matters is writing the
problems down and explaining how they were corrected.**

### 10.1 Accidentally deleting the adb key broke the connection authorization 【recovered】

- **Problem**: while troubleshooting the guest adb `unauthorized` state, `~/.android/adbkey*` was
  deleted and the adb server restarted. This invalidated all established authorizations and briefly
  interrupted guest adb access.
- **Impact**: broke the existing forensics connection; authorization had to be re-established.
- **Correction**: afterwards only `adb kill-server` / `adb connect` are used; **keys are no longer deleted**.
  Recovered after re-authorization.
- **Lesson**: the first tool for connection troubleshooting is restarting the server, not clearing credentials.

### 10.2 A `bind mount` broke the guest `/system` projection 【recovered】

- **Incident**: after `bind mount /system` onto an *already-stacked* target (already carrying
  `tmpfs`/`proc`), the guest's `/system` projection failed (`/system/bin/sh`, `/system/bin/toybox`,
  `/system/build.prop` all became `No such file`; `adb shell` could not start, since it always execs
  `/system/bin/sh`).
- **Cause**: the guest's userspace mount implementation mishandles "bind-mounting onto an
  already-mounted target", overwriting/unbinding the source `/system` VFS mapping. This is an
  **in-memory state corruption**; container files on disk were untouched.
- **Recovery**: restarting the guest instance fully restored it (`/system/bin/sh` 299616 B,
  `/system/bin/toybox` back; residual mounts cleared; mount table back to ~48 entries).
- **Follow-up handling**: mount tests now use `/data/local/tmp` as the target, `umount` immediately
  after each test, and **no `bind mount` onto system paths**.
- **Methodological significance**: the incident itself proves that **the guest's mount state is
  userspace in-memory state, not host-kernel state**; restarting the app fully resets it, and the host
  kernel never held those mounts at all.

### 10.3 A NULL-pointer test program polluted the data 【self-caught and corrected】

- **Problem**: one version of the `setsockopt` test passed `optval` as `0` (NULL), causing options such
  as `SO_REUSEADDR` that should succeed to all return `EINVAL`.
- **Impact**: uncorrected, it would have wrongly concluded "most socket options are unsupported".
- **Correction**: the program was rewritten with valid pointers and the **two-sided comparison** redone,
  yielding the correct conclusion (only some `IPPROTO_IP` options are intercepted).
- **Lesson**: the test program's own bugs and the projection layer's behavior must be told apart by
  **controlled experiments**.

### 10.4 P1 (highest-privilege) observation archive was briefly deleted by mistake 【restored in this version】

- **Problem**: when drafting v2.0, because the current machine had only P0 + P2 tiers, the text stated
  "this report has no P1 tier" and **deleted the P1 observations obtained earlier on a root-enabled
  comparison carrier**.
- **Correction**: **P1 observations must not be deleted just because the carrier is absent.** This
  version restores them in full: §2.2 (comparison carrier), §4.2 (namespaces / mounts),
  §4.4 (`maps` / `fd`), §4.9 (storage), §4.13 (ELF loader).
- **Lesson**: deleting evidence is far more dangerous than adding conclusions; a report should preserve
  its historical forensics record.

### 10.5 This version's own experimental-design flaw 【corrected】

#### 10.5.1 "Host EACCES vs guest ret=0" is an invalid control

- **Problem**: the v2.0 draft's §4.6.1 treated "host uid 2000 gets `EACCES` vs guest uid 2000 gets
  `ret=0`" as a decisive controlled experiment.
- **Why it is invalid**: the host's uid 2000 getting `EACCES` from `mount()` is the **necessary outcome
  of lacking `CAP_SYS_ADMIN`**, unrelated to any projection layer. The comparison only proves
  "**the two sides' permission models differ**", not "the guest's `mount()` cannot be executed by the
  host kernel" — because in that comparison the host kernel **was never allowed to execute**.
  Mistaking a **permission difference** for an **architecture difference** is result confusion.
- **No fair host-side control is constructible here** (measured): the primary carrier has no root;
  `unshare -Urm` → `Invalid argument`; `unshare -m` → `Operation not permitted`.
- **Correction**: §4.6.1 has been rewritten as a **guest-side uid sweep** (any uid, incl. 10000, can
  `mount(tmpfs)`), and §4.6.2 explicitly states the host-side failure is **a reference only, not
  evidence**.
- **Lesson**: a controlled experiment must keep the tested factor **at a state where success is
  attainable on both sides**; when one side can never succeed due to environmental limits, the
  difference reflects the environment, not the mechanism under test.

### 10.6 Cognitive biases in the earlier analysis 【corrected in this version】

| # | Earlier bias | Correction in this version | Nature |
|---|---|---|---|
| 1 | "Host mount table shows nothing ⇒ no mount capability" | guest uid 10000 can still `mount(tmpfs)` + whitelist + host mount table unchanged | incomplete methodology |
| 2 | "Can reach network ⇒ reuses host stack" | hybrid model (real socket + control-plane interception) | reverse-inferring implementation from result |
| 3 | "Simple library hijack, handled in place" | cross-component IPC + userspace VFS + mount tree | oversimplified model |
| 4 | "Host cannot see it ⇒ the function does not exist" | userspace builds the semantics; the host is inherently blind | paradigm blind spot |
| 5 | treating A/B/C as "three internal implementation branches" | changed to "three externally observable processing paths" | overreaching wording |
| 6 | treating "the field-by-field grind / `/proc` consistency" as the main engineering effort | the main effort is the **cross-process semantic shim runtime** (see §5.5); the grind is only surface-level | mistaking the surface for the hard part |

### 10.7 Still-open problems (undetermined)

- the exact 2nd-layer seccomp strategy (requires reading the BPF program);
- the IPC message binary protocol;
- the mount tree's internal data structures;
- routing / DNS / VPN paths (this round measured only the socket control plane).

> **Summary**: 10.1–10.4 are **actual problems encountered during forensics**, all handled or corrected;
> 10.5 reminds the reader of the systematic biases in earlier analysis. These records do not weaken the
> report — they make the evidence chain auditable.

---

## 11. Publication Notes

### 11.1 Publishable

- The entire report is **behavioral observation + controlled experiments**, with no disassembly or
  decompilation; it falls under architecture analysis and interoperability research.
- Observation was performed on owned devices and an owned, licensed copy.
- Keep the AI-assistance disclosure (§1.2) and the reproducible commands (§9) — **these are the main
  source of this report's credibility**.
- Keep the **K1/K2/K3 determinacy layering + controlled-experiment design** (§0, §1.1) — it is the
  core methodology of this version.

### 11.2 Declarations that must be retained

1. **AI-assistance disclosure** (§1.2), including the self-correction note.
2. **Permission-tier table** (§1.3 / §1.4), stating which tier (P0/P1/P2) yielded each conclusion;
   **P1 observations are archived from the early comparison carrier and must be retained**.
3. **The definition of the three processing paths (A / B / C)** (§5.1) — it organizes all conclusions.
4. **Environmental confounders** (§2.4).
5. **A/B/C/U evidence grades and K1/K2/K3 determinacy levels throughout**, plus the §8 limitations.
6. **The forensics problem/correction record** (§10), including incidents and self-corrections.
7. **Methodological floor**: external behavior constrains but usually does not uniquely determine
   internal implementation; **controlled experiments are the main means of upgrading U-level
   conclusions to K1**.

---

## Appendix A · Project Files

| File | Content |
|---|---|
| `README.md` / `README_EN.md` | architecture analysis (CN/EN) |
| **`架构速览.md`** / **`架构速览_EN.md`** | **⭐ quick start (CN/EN): one-minute overview of the idea, pros and cons** (conjectural summary) |
| **`垫片分层模型_进程与线程.md`** | **how the shim is layered: 1:1 guest-process/thread ↔ host-process/thread mapping + shim thread + broker** (Chinese) |
| **`复现路线与垫片设计.md`** | **engineering concept: reproduction roadmap + shim design + high-performance design** (Chinese) |
| `P1_归档_结构性观测.md` | archive of P1 (host root) **structural** observations from the early root-enabled comparison carrier (Chinese) |
| `假设验证_共享mm证伪.md` | hypothesis—criterion—falsification record for an external AI's "shared mm_struct / signal isolation" model (Chinese) |
| `重新取证报告_2026-09-23.md` | full record of this round of dual-device controlled experiments |
| `取证_2026-09-23/` | raw evidence archive (mount tables, filesystems, IPC, etc.) |

---

*End of report. All K1 conclusions are reproducible with the §9 commands under the same environment;
K2/K3 conclusions should be read as candidate architecture models, not confirmed internal code structure.*
