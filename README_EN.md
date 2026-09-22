# VPhoneGaGa 3.4.0 — Architecture Forensics Report

| Item | Content |
|---|---|
| Report version | **v1.0** (standard release) |
| Companion document | [`ARCHITECTURE.md`](ARCHITECTURE.md) — component-level architecture, measured boot timeline, open-source reproducibility assessment (Chinese) |
| Target | `com.vphonegaga.titan` **3.4.0** (versionCode 3688) |
| Method | Pure runtime behavior forensics (no disassembly, no decompilation, no IDA / Ghidra / Frida) |
| Carriers | 2 host devices + an internal shell inside one guest VM instance |
| Permission tiers | Host adbd (unrooted) · Host root (comparison device only) · Guest-internal shell |
| **AI assistance** | **pi.dev (deepseek-v4-flash)** |
| Evidence grading | Every claim tagged **A / B / C / U**, plus the **permission tier P0/P1/P2** required to obtain it |

[中文](./README.md)
**Based on the Chinese text, some translations may not be timely.**

---

## 0. Abstract

This report reconstructs the low-level architecture of the closed-source Android virtualization
product **VPhoneGaGa 3.4.0**, using **unrooted runtime observation** on the host side combined with
**a shell obtained from inside the guest VM**.

Five central findings:

1. **Available observation does not support classifying it as a complete LibOS; it is also not a
   namespace container.** Guest processes share the host kernel and the same UID (the app's UID),
   with no PID, UTS, USER, or IPC isolation. The evidence better supports a **hybrid architecture of
   "host-kernel reuse + syscall projection + userspace filesystem/device abstraction"** (see §5.0).
2. **Syscall interception is real — but it is not "hijacking SVC trap instructions".** It is a
   *second, self-installed seccomp filter*. The `Seccomp_filters` field in `/proc/<pid>/status`
   provides layered proof: host app processes carry **1** filter; all **85** guest processes
   carry **2**.
3. **`/proc` is fabricated wholesale.** With a guest-internal shell, it is possible to read the
   *same process* from both sides and obtain two contradictory self-descriptions. The guest
   reports `uid=0`, full capabilities, `Seccomp: 0`, kernel 4.14.42, Cortex-A53, 4 GB RAM. The
   host kernel reports `uid=10383`, `CapEff=0`, `Seccomp: 2`, kernel 5.15.167,
   Snapdragon 8 Gen 2, 14.8 GB RAM.
4. **Guest root is a Magisk 26.0 stack running inside the app's UID.** The host
   device has **no usable root whatsoever** (there is not even a `su` binary). The guest's
   `magiskd / lspd / zygiskd64 / zygiskd32` all have the **virtual kernel as their real parent** on the
   host side (the parent shown inside the guest is a *reconstructed* logical tree — see
   ARCHITECTURE.md §1.3), and all run under host UID 10383 with zero capabilities.
5. **Its technical positioning is closer to "a syscall projection and device-emulation layer"
   than to "a userspace kernel reimplementation".** Request handling falls behaviourally into three
   paths (see **§5.0**): **B synthesis** (identity and hardware-info reads — `getuid`/`capget`/`/proc/*`;
   never enters the kernel; measured), **C redirection** (filesystem requests — path rewritten, then a
   genuine host-kernel mmap; measured), and **A passthrough** (everything else, handed verbatim to
   the host kernel; architecturally inferred). In one sentence: **it did not build a kernel — it
   acted one out.**

**Scope limitation**: this report covers processes, scheduling, syscalls, filesystems, storage
formats, and `/proc` projection only. **It does not cover networking** — no conclusions are drawn
about the guest's network implementation.

---

## 1. Methodology, Permission Tiers, and Compliance

### 1.1 AI assistance disclosure

| Item | Detail |
|---|---|
| AI interface | **pi.dev** |
| Model | **deepseek-v4-flash** |
| Scope of involvement | Observation planning, command sequencing, raw-output organization, cross-checking, conclusion drafting, report writing, and EN/CN localization |
| Not involved | Every command was executed on real hardware; every output is a genuine terminal echo, not AI-generated or inferred |

**Risk that must be stated**: AI-assisted analysis produces errors.
The **two misjudgments** listed in §6 "Corrections" were both produced by this report's
AI-assisted analysis and were corrected after subsequent measurement:

1. It was concluded that "`[REDACTED]` images have no plaintext on disk and must be decrypted in memory"
   — reading the file at the mapped offsets yielded plaintext ELF and ARM64 instructions, so the
   conclusion was overturned.
2. It was concluded that "the guest tree's `cpuset` claim is refuted" — a controlled experiment
   showed the guest tree does indeed remain in `top-app`, and the report corrected itself.

These two entries are listed not as a disclaimer but as a warning to the reader:
**this report's credibility comes from the reproducible commands in §8, not from anyone's
authority.**

### 1.2 Permission tiers (used throughout)

All observations are strictly separated by three permission tiers. Where a conclusion is verified
at multiple tiers, the **lowest tier** determines its grade.

| Tier | Code | Identity | How obtained | Availability |
|---|---|---|---|---|
| Host adbd (**unrooted**) | **P0** | `uid=2000(shell)`, `context=u:r:shell:s0` | `adb shell` | **Both** carriers |
| Host root | **P1** | `uid=0(root)` | `su -c` (**comparison device B only**, Magisk Alpha) | Comparison carrier only |
| Guest-internal shell | **P2** | guest `uid=2000` → `su` → guest `uid=0` | `adb connect 127.0.0.1:6556` | Primary carrier's guest only |

> **Important**: primary carrier Device A **has no P1 tier at all** (no `su`, no magiskd).
> Therefore **every observation requiring P1 was obtained only on comparison Device B**, and each
> such conclusion is annotated accordingly.

### 1.3 Actual permission boundaries per tier (measured)

| Observation target | P0 (unrooted) | P1 (root) | P2 (inside guest) |
|---|---|---|---|
| `ps -A -o PID,PPID,USER,NAME` | ✅ | ✅ | ✅ |
| `/proc/<pid>/status` (Name/PPid/Uid/Gid/CapEff/CapPrm/Seccomp/Seccomp_filters/NoNewPrivs/TracerPid/NSpid) | ✅ | ✅ | ✅ |
| `/proc/<pid>/cgroup` | ✅ | ✅ | ✅ |
| `/proc/<pid>/oom_score_adj` | ✅ | ✅ | ✅ |
| `/proc/<pid>/cmdline` | ✅ | ✅ | ✅ |
| `/proc/net/unix` (socket name enumeration) | ✅ | ✅ | ✅ |
| `dumpsys` / `pm` / `getprop` | ✅ | ✅ | ✅ |
| **`readlink /proc/<pid>/exe`** | ❌ | ✅ | ✅ |
| **`/proc/<pid>/ns/` (namespaces)** | ❌ DENIED | ✅ | ✅ |
| **`/proc/<pid>/maps` (memory mappings)** | ❌ DENIED | ✅ | ✅ |
| **`/proc/<pid>/fd/` (file descriptors)** | ❌ DENIED | ✅ | ✅ |
| **`/proc/<pid>/environ`** | ❌ DENIED | ✅ | ✅ |
| **`/data/data/<pkg>/` (private data dir, container files)** | ❌ DENIED | ✅ | — |
| **`/data/app/*/<pkg>*/lib/arm64/` (APK native libs; the `[REDACTED]`/`strings` targets)** | ❌ DENIED | ✅ | — |

### 1.4 Techniques used

| Area | Technique | Tier |
|---|---|---|
| Process & scheduling | `ps`, `/proc/<pid>/{status,cgroup,oom_score_adj,cmdline}` | P0 |
| Kernel state fields | `Seccomp` / `Seccomp_filters` / `CapEff` / `NoNewPrivs` / `TracerPid` / `NSpid` | P0 |
| IPC name enumeration | `/proc/net/unix` | P0 |
| APK component metadata | `[REDACTED] -lW / -dW / --[REDACTED]`, `strings`, `od` | P1 |
| Storage container format | Hex dump of file headers (`od`), magic comparison, image header decoding | P1 |
| Memory & descriptors | `/proc/<pid>/{maps,fd,ns}` | P1 |
| Guest-internal view | The guest's own adbd (`127.0.0.1:6556`) shell + `su` | P2 |

### 1.5 Techniques explicitly *not* used

No disassembly of any SO/DEX. No decompilation. No IDA / Ghidra / Frida / Xposed.
No parsing of ELF instructions inside `readonly.bin`. No attempt to extract, decrypt, or repack any
image. **No packet capture, routing, or traffic analysis of any kind.**

### 1.6 Compliance

- All observation was performed on **owned devices and an owned, licensed copy**.
- This report describes **what was observed**, never **how to circumvent, patch, or extract**.
- The report contains **no** steps, keys, or offset tables usable to defeat the product's
  protection mechanisms.
- This constitutes **architecture analysis and interoperability research**, not cracking.

### 1.7 Evidence grading

| Grade | Meaning |
|---|---|
| **A** | Reproducible without root (**P0-reachable**) |
| **B** | Requires root (**P1-reachable**) |
| **C** | Requires guest-internal shell (**P2-reachable**) |
| **U** | **Undetermined** with current instrumentation |

---

## 2. Test Devices and Environments

### 2.1 Device A — primary carrier (used to test "no host root required")

| Item | Observed value | Tier |
|---|---|---|
| Brand / model | OnePlus / **PJE110** | P0 |
| SoC | Qualcomm **SM8550** (Snapdragon 8 Gen 2, codename `KALAMA`) | P0 |
| CPU | 8 cores: 3×`0xd46` (Cortex-A510) / 2×`0xd47` (A715) / 2×`0xd4d` (A710) / 1×`0xd4e` (X3) | P0 |
| RAM | 15,496,684 kB ≈ **14.8 GiB** | P0 |
| Storage | 933 GB (403 GB used) | P0 |
| OS | **ColorOS/OxygenOS 15.0.0.870(CN01)**, Android **15** / SDK **35** | P0 |
| Fingerprint | `OnePlus/PJE110/OP5CF9L1:15/TP1A.220905.001/U.1d94395_275952_27eb03:user/release-keys` | P0 |
| Build date | 2025-09-26 | P0 |
| Kernel | `5.15.167-android13-8-o-01144-gdc8278c1c5f9` | P0 |
| Integrity | `ro.build.flavor=qssi-user`, `type=user`, `tags=release-keys`, **bootloader locked**, `verifiedbootstate=green` | P0 |
| **Root status** | **No usable root**: `command -v su` fails, `/system/bin/su` absent, no magiskd, no root processes | P0 |
| Residual traces | **KernelSU manager v3.3.0 installed**; `/data/adb` exists but is unreadable ⇒ **not a "never-rooted" device** | P0 |

> This is the report's **primary carrier**. Its value lies in the fact that the guest's Magisk /
> LSPosed / Zygisk appeared **while the host had no usable root path at all**. It also
> **provides no P1 tier**, so every root-requiring observation depends on Device B.

### 2.2 Device B — comparison carrier (the only P1 source)

| Item | Observed value | Tier |
|---|---|---|
| Brand / model | Redmi / **Redmi K30 5G** (`picasso`) | P0 |
| SoC | Qualcomm **SM7250** (Snapdragon 765G) | P0 |
| CPU | 8 cores: 2×`0x804` (Cortex-A76) / 6×`0x805` (Cortex-A55) | P0 |
| RAM | 7,661,616 kB ≈ **7.3 GiB** | P0 |
| OS | **LineageOS 22.2 UNOFFICIAL** (Android **15** / SDK **35**) | P0 |
| Build | `lineage_picasso-userdebug 15 BP1A.250505.005 eng.cnmrli test-keys` | P0 |
| Build date | 2025-09-28 (**unofficial; builder field is a personal handle**) | P0 |
| Kernel | `4.19.314-Hanabi-2.2-g6e7223ac503a-dirty` | P0 |
| **Root status** | **Magisk Alpha running**: package `io.github.vvb2060.magisk` v`c3db2e36-alpha`; `magiskd` (uid 0) alive; Zygisk module `playintegrityfix` loaded | P0 / **P1 source** |
| Property reliability | **Unreliable**: `ro.build.tags=release-keys` contradicts `test-keys` in display.id; `type=user` contradicts the `userdebug` flavor; `verifiedbootstate=green` + `flash.locked=1` contradicts "unlocked and rooted" ⇒ **Magisk property resets are in effect** | P0 |

> **This device cannot be used to validate the "no host root required" claim.** It only supplies
> the P1 tier and serves as a control. Its `getprop` output is untrustworthy.

### 2.3 Guest VM instance — running inside Device A (P2 source)

A guest-internal shell was obtained through the guest's own adbd (`adb connect 127.0.0.1:6556`).
Its ADB banner advertises `product:cancro model:Nexus device:android`.

| Item | Guest self-description | Host kernel reality | Tier |
|---|---|---|---|
| OS version | Android **10** / SDK **29** | Android 15 / SDK 35 | P2 / P0 |
| Fingerprint | `samsung/cancro/android:10/KOT49H/eng.build.20220315.203416:user/release-keys` | `OnePlus/PJE110/…:15/…` | P2 / P0 |
| `ro.build.id` | `KOT49H` (**the Android 4.4 build ID**, deliberately mismatched) | — | P2 |
| Model | `model=Nexus`, `brand=samsung`, `device=android`, `name=cancro` | PJE110 / OnePlus | P2 / P0 |
| Build date | 2022-03-15 20:31:13 PDT | 2025-09-26 | P2 |
| Security patch | 2019-09-05 | — | P2 |
| Kernel | `4.14.42-titan (titan@ubuntu) gcc 4.8.4 #34 SMP PREEMPT 2019-11-09` | `5.15.167-android13-8-…` | P2 / P0 |
| CPU | Cortex-A53 (`0x801`) × 8 | Snapdragon 8 Gen 2 (`0xd46/0xd47/0xd4d/0xd4e`) | P2 / P0 |
| Memory | 4,063,232 kB ≈ **3.9 GB** | 15,496,684 kB ≈ **14.8 GB** | P2 / P0 |
| `/data` size | 933 GB | 933 GB (**not disguised — leaks**) | P2 |
| Root | **Magisk 26.0** (`26.0:MAGISK:R` / `26000`) | uid 10383 / CapEff 0 | P2 / P0 |
| Packages | 141 installed (no GApps) | — | P2 |
| System binaries | 379 in `/system/bin` | — | P2 |
| Serial | `[REDACTED]` (hard-coded) | — | P2 |

> ⚠️ **This guest instance is not factory-fresh**: `/data/adb/start.sh` is owned by `u0_a100`,
> a 1.7 MB `su_arm64` is present, and `/data/adb/modules/zygisk_lsposed` exists.
> Any statement that "the guest ships with LSPosed" must note that this was user-installed inside
> the instance.

### 2.4 Environmental confounders (disclosed)

| Confounder | Effect | Handling |
|---|---|---|
| **KernelSU manager + `/data/adb`** (Device A) | Shows the device was previously rooted | Disclosed; but **no usable root path exists now** |
| **Magisk Alpha + Zygisk module** (Device B) | Properties reset; root modules can modify cgroups freely | Demoted to control; its cgroup data contradicts Device A, so Device A prevails |
| **User-installed LSPosed module inside the guest** | Guest is not a pristine instance | Disclosed |

---

## 3. Software Versions

| Item | Value | Tier |
|---|---|---|
| Package | `com.vphonegaga.titan` | P0 |
| **Version name** | **3.4.0** | P0 |
| Version code | **3688** | P0 |
| minSdkVersion | **21** | P0 |
| **targetSdkVersion** | **29** (Android 10) | P0 |
| Instance directory | `files/instance1/androidfs_10.0.0/` | P1 |
| Device A / B version | **Identical** (3.4.0 / 3688) | P0 |

> **`targetSdk=29` is one important compatibility condition of the current implementation route.**
> Pinning targetSdk to Android 10 substantially reduces friction from Android 11+ scoped storage,
> package visibility, background execution, and process-count restrictions, and considerably lowers
> the framework constraints on hosting a complete Android 10 userspace inside an app sandbox.
>
> ⚠️ **However, whether it is a *necessary* condition for the architecture has not been verified by
> a controlled experiment** (targetSdk=30/31 behaviour was not tested). **Grade U.**

**Guest image**: an Android 10 system built 2022-03-15 (`eng.build.20220315.203416`), with a
security patch level of 2019-09-05 — consistent with a genuine Android Q build. 【P2】

---

## 4. Observations

> Every observation is tagged with its **evidence grade** and the **permission tier** required.

### 4.1 Process topology — **Grade A / P0**

Under the host `zygote64` (PID 1436 on Device A):

```
host zygote64
├── com.vphonegaga.titan              uid 10383   cpuset:/foreground
└── com.vphonegaga.titan:instance1    uid 10383   cpuset:/top-app
    └── titan64_0:kernel              ← guest virtual kernel (64-bit)
        ├── titan32_0:kernel          ← guest virtual kernel (32-bit)
        ├── titan64_1:init            ← guest init
        │   ├── titan64_59:netd / 60:zygote64 / 105:surfaceflinger
        │   ├── titan64_107:adbd      ← guest runs a full adbd
        │   ├── titan64_164:su
        │   └── titan64_249:system_server
        ├── titan64_43:magiskd        ← parent is the virtual kernel, **not init**
        ├── titan64_56:lspd           ← LSPosed daemon, parent = virtual kernel
        ├── titan64_259:zygiskd64     ← parent = virtual kernel
        └── titan32_506:zygiskd32     ← parent = the **32-bit** virtual kernel
```

**Scale**: **85** guest processes (snapshot; 87 on comparison Device B). 100 PID directories are
visible from inside the guest. 【P0/P2】

**Naming scheme**: `titan{32,64}_<guest virtual PID>:<guest process name>`. That virtual PID
corresponds exactly to what `ps` reports inside the guest (see §5.2). 【cross-verified P0 + P2】

**One topological correction**: `com.vphonegaga.titan` and `:instance1` share the **same PPid**
(host zygote) — they are **siblings**, not parent and child. The virtual kernel's parent is
`:instance1`.

### 4.2 Privileges and scheduling — **Grade A / P0**

| Observation | Value |
|---|---|
| UID of all guest processes | **10383** (app UID, no exceptions) |
| `CapEff` / `CapPrm` of all guest processes | `0000000000000000` |
| `NoNewPrivs` of all guest processes | `1` |
| `TracerPid` of all guest processes | **0** (⇒ **ptrace-based interception is ruled out**) |
| `Seccomp` of all guest processes | `2` |
| **`Seccomp_filters` of all guest processes** | **`2`** ← see §4.3 |
| Namespaces | `/proc/<pid>/ns/` exposes only `cgroup` / `mnt` / `net`; **no `NSpid` field** ⇒ **no PID namespace**, and no UTS / IPC / USER / TIME 【P1】 |
| Mounts | Guest `mountinfo` is identical to the host app's (152 entries); **no product-specific mount points** ⇒ the "virtual partitions" are **not mounts** 【P1】 |
| cgroup | The entire guest tree sits in `cpuset:/top-app` while its parent `instance1` sits in `/foreground` |
| `oom_score_adj` | Entire guest tree `0`; `instance1` is `101` |

### 4.3 ★ The second seccomp filter — **Grade A / P0 (core evidence)**

The `Seccomp_filters` field in `/proc/<pid>/status` provides irrefutable layered evidence:

| Process | `Seccomp` | **`Seccomp_filters`** |
|---|---|---|
| Host `init` / `zygote64` / `netd` | 0 | 0 |
| Host `systemui` | 2 | **1** |
| `com.vphonegaga.titan` | 2 | **1** |
| `com.vphonegaga.titan:instance1` | 2 | **1** |
| **`titan64_0:kernel`** | 2 | **2** ← the transition point |
| **All 85 guest processes** | 2 | **2** (100%) |

**Interpretation**:
- Android installs exactly one seccomp filter on every app process (installed by zygote), so the
  host side is uniformly 1.
- seccomp filters **can only be stacked, never removed**. The 1→2 transition occurs *after*
  `instance1` forks the virtual kernel and *before* guest code runs.
- Therefore **the evidence best supports the explanation that the second filter was installed by the
  guest virtual kernel during bootstrap and inherited by its descendants**; however, **the specific
  installing caller has not been directly observed**. Other theoretical paths cannot be fully ruled
  out (e.g. `instance1` installing it within a very short window, a loader/initialisation component
  installing it, or an as-yet-unlocated init thread doing so) — they merely fit the overall
  architecture far less well.
- Cross-check (P1): `libuserkernel64.so`'s string table contains `PR_SET_SECCOMP`,
  `PR_GET_SECCOMP`, `PTRACE_SEIZE`, `PTRACE_GETREGS`, and similar constants.
- Device A has **no root, no Magisk, and no Zygisk**, so this layer cannot originate from the host.

⇒ **VPhoneGaGa's userspace syscall interception is real, implemented at the seccomp layer.**
(The exact policy — `RET_USER_NOTIF` / `RET_TRACE` / `RET_ERRNO` — requires reading the BPF
program: **Grade U**.)

### 4.4 ★ Wholesale `/proc` fabrication — **Grade C / P2 versus P0**

With a guest-internal shell, the *same process* can be read from both sides:

| Observation | Guest view (P2) | Host kernel truth (P0) | Verdict |
|---|---|---|---|
| `su -c id` | `uid=0(root) gid=0(root)` | uid **10383** | **fabricated** |
| `CapEff` / `CapPrm` | `0000003fffffffff` (full set) | `0000000000000000` | **fabricated** |
| `Seccomp` | **0** | **2** (with 2 filters) | **fabricated** |
| `NoNewPrivs` | **0** | **1** | **fabricated** |
| PID space | `init=1`, `magiskd=43`, `zygote64=60`, `system_server=249` | 7098 / 7227 / 7263 / 7957 | **virtual PID mapping** |
| `/proc` numeric dirs | 100 (max PID 2554) | 300+ on the host | **filtered** |
| Host real PIDs visible | **No** (6341/6839/7024/7263 all invisible) | — | **filtered** |
| `/proc/version` | `4.14.42-titan (titan@ubuntu) gcc 4.8.4 …2019` | `5.15.167-android13-8-o-01144` | **fabricated** |
| `/proc/cpuinfo` | `CPU part: 0x801` (Cortex-A53) × 8 | `0xd46/0xd47/0xd4d/0xd4e` | **fabricated** |
| `/proc/meminfo` | `4,063,232 kB` | `15,496,684 kB` | **fabricated** |
| `/proc/uptime` | `386296188` s (**≈ 12.2 years**, and idle > uptime) | `621609.78` s | **fabricated (and broken)** |
| `/proc/self/maps` | `/system/lib64/libnetd_client.so`, dev `03:08`, ino `3080` | `…/androidfs_10.0.0/system/readonly.bin`, dev `fd:26`, ino `118337` | **path rewritten** |
| `/proc/self/fd` | `0/1/2 -> sock:[725]` | real socket | **fabricated (malformed)** |
| `/proc/1/exe` mode | `lr--r--r--` | real procfs is always `lrwxrwxrwx` | **fabrication tell** |
| `cgroup` | `2:cpu:/apps` / `1:cpuacct:/` (Android 10 layout) | 6 controllers + `/uid_10383/pid_6839` | **fabricated** |
| `/proc/mounts` | `/dev/block/platform/host/by-name/system` as ext4 | no such mount | **fabricated** |
| `df /data` | 933 GB | 933 GB | **leaks (not disguised)** |
| SELinux context | `--  u:object_r:toolbox_exec:s0` (stray `--`) | — | **emulation artifact** |

**Key insight**: the filter fabricates `Seccomp` as `0` — it intercepts the process's syscalls
while simultaneously telling that process *"I do not exist."*

### 4.5 ★ Self-incriminating fabrication artifacts — **Grade C / P2 (strongest evidence)**

**One kernel state, three interfaces, two different answers:**

```
$ cat /proc/self/mountinfo
28 26 3:8 / / ro,seclabel,barrier=1 shared:2 - ext4 /dev/block/platform/host/by-name/system rw,seclabel

$ cat /proc/mounts
/dev/block/platform/host/by-name/system / ext4 ro,seclabel,barrier=1 0 0

$ mount
/dev/block/mtdblock0 on / type ext4 (ro,seclabel,barrier=1)
                    ^^^^^^^^^^ entirely different device name
```

Other artifacts:

| # | Artifact | Significance |
|---|---|---|
| 1 | `/proc/mounts` and `mount` disagree on the root device | Same state, two answers ⇒ **highly consistent with an interface/path-level projection model** (not direct proof) |
| 2 | `/proc/uptime` = 386,296,188 s (**12.2 years**), with idle > uptime | Struct assembled incorrectly |
| 3 | `/proc/self/fd` shows `sock:[725]` | The Linux kernel always prints `socket:[inode]`; the inode is also implausibly small |
| 4 | `/proc/1/exe` mode is `lr--r--r--` | Real procfs `exe`/`cwd` are always `lrwxrwxrwx` |
| 5 | Device path `platform/**host**/by-name/system` | Real platforms are named `1d84000.ufshc` etc. **`host` is the product's own naming — self-exposure** |
| 6 | `/share` mount source literally reads `/storage/emulated/0/Android/data/com.vphonegaga.titan/files/instance1/shared` | **Host path leak** |
| 7 | `context=--  u:object_r:toolbox_exec:s0` | SELinux emulation assembly artifact |

⇒ **Using the product's own bugs to prove it is fabricating** is stronger than any inference.

**Implementation model (highly consistent with observation, but not direct proof)**: the real procfs
is still the host kernel's (otherwise `cat /proc/version` would produce nothing), while
**`openat` / `read` on specific paths is intercepted by the second seccomp filter**, which returns
**synthesized content** from memory.

The hundreds of `memfd:titan-tmp-inode-N (deleted)` entries in the host-side fd table 【P1】 only
establish that **a large number of anonymous/temporary memory objects are associated with a
userspace virtual-file implementation**. Treating "they are the entities behind every fake `/proc`
file" as an established fact **exceeds the evidence boundary** — the accurate statement is that the
phenomenon is **highly consistent with the implementation model above**.

Paths replaced, measured at P2: `/proc/<pid>/{status,cgroup,maps,fd/*,exe}`,
`/proc/{mounts,self/mountinfo}`, `/proc/{cpuinfo,meminfo,uptime,version}`.

### 4.6 Peripheral proxy channels `@titan-pipe-*` — **Grade A / P0 (no root needed)**

`/proc/net/unix` is fully readable as the shell user and exposes the IPC channel names between the
guest subsystems and the host:

```
@titan-pipe-1-framebuffer      @titan-pipe-1-input         @titan-pipe-1-activity
@titan-pipe-1-gsm              @titan-pipe-1-gps
@titan-pipe-1-camera  (+ name=camera0 / camera1)           @titan-pipe-1-sensors
@titan-pipe-1-fingerprint      @titan-pipe-1-crash         @titan-pipe-1-hw
@titan-pipe-1-ipc              @titan-pipe-1-network
@titan-process-worker-server-1-<PID>    × 86
```

**The above is strictly a raw name enumeration from `/proc/net/unix`. This report draws no
network or communication-architecture conclusions from it.**

These correspond exactly to strings in the host-side `libuserkernel64.so`:
`titan-virtpipe-dma-%u-%d`, `titan-virtpipe-shm-%u-%d`, `titan-%u-process-monitor`. 【P1】

⇒ **This naming reveals how guest peripherals are proxied**: camera / GPS / telephony / sensors /
fingerprint / graphics / input / Activity each have their own abstract Unix socket channel.
The guest also exposes product-specific properties `android.host.adb.port=6556` and
`android.host.adb.server.port=6038`. 【P2】

### 4.7 Storage layer — **Grade B / P1**

Host-side private directory `files/instance1/androidfs_10.0.0/` (1.8 GB total):

```
├── androidfs.bin          64 B     magic [REDACTED] / raw bytes [REDACTED]
├── locales.bin           491 B
├── config.gz            1305 B
├── fscache.bin        402,698 B
├── system/
│   ├── readonly.bin   1,557,878,007 B   (1.45 GiB)  magic [REDACTED] / raw bytes [REDACTED]
│   ├── superblock.bin  16 B             magic [REDACTED] / raw bytes [REDACTED]
│   └── 00000000/       writable index objects
├── vendor/  readonly.bin 30,533,337 B + superblock.bin 16 B
├── data/    831 index objects + fscache.bin 67,108,864 B (64 MiB) + superblock.bin 16 B
├── cache/   superblock.bin 16 B + 00000000/ (14 entries)
└── root/
    ├── block.img        8,388,608 B    ← a genuine Android boot image
    ├── readonly.bin     2,696,464 B
    └── superblock.bin          16 B
```

**Header field decoding (cross-validating)**:

```
<part>/superblock.bin (16 B)          <part>/readonly.bin (first 64 B)
  +0x00  42 50 55 53  "[REDACTED]"            +0x00  41 54 49 54  "[REDACTED]"
  +0x04  10 00 00 00  = 16  ← hdr len    +0x04  40 00 00 00  = 64  ← hdr len
  +0x08  9d 11 00 00  = 4509 ← count     +0x08  9d 11 00 00  = 4509 ← **identical to superblock**
         system=4509 vendor=503
         data=3800   cache=11  root=23
```

The object count in the `readonly.bin` header **exactly equals** the corresponding partition's
`superblock.bin` count (system 4509 / vendor 503). This is the hardest cross-evidence for the
layering "[REDACTED] is the index, [REDACTED] is the data".

**Magic-number byte order (must be stated)**: all three magics are stored on disk as **two 16-bit
little-endian half-words**, so the **raw byte order is `[REDACTED]` / `[REDACTED]` / `[REDACTED]`**; `od -x` renders
them as big-endian character pairs, yielding `[REDACTED]` / `[REDACTED]` / `[REDACTED]`. This must be spelled out, or
any reader re-checking with `xxd` / `od -c` will conclude the data was fabricated.

**`root/block.img` is a structurally valid Android boot image (header v0)**:

```
+0x00  41 4e 44 52 4f 49 44 21   "[REDACTED]"
+0x08  70 0e 03 00   kernel_size  = 200,304
+0x0C  00 80 00 10   kernel_addr  = [REDACTED]   (standard ARM64)
+0x10  ec f0 28 00   ramdisk_size = 2,682,092
+0x14  00 00 00 11   ramdisk_addr = 0x11000000   (standard)
+0x20  00 01 00 10   tags_addr    = 0x10000100
+0x24  00 10 00 00   page_size    = 4096
+0x30  74 69 74 61 6e   name = "titan"
```

⇒ **The claim "the boot partition is simulated in userspace" is upgraded from inference to
measurement.**

**Container format lineage**: the APK ships `libp7zip.so` (3.1 MB) whose string table contains
`[REDACTED]`, `AES256CBC`, `[REDACTED]`, `BCJ2`, `Deflate64`, `PPMd`.
⇒ [REDACTED]/[REDACTED]/[REDACTED] is not a from-scratch encrypted filesystem but a **private wrapper over the 7-Zip
family**.

**`readonly.bin` is *not* encrypted (this overturns an earlier conclusion)**: guest processes
**mmap the file directly** (166 mappings in guest init, 358 in the guest SF), and reading the file
at those mapped offsets yields `7f 45 4c 46` (ELF) and valid ARM64 instructions.
⇒ It is a **plaintext, page-aligned, directly mmap-able flat ELF container** (conceptually close to
EROFS / incfs).

**Where the AES actually goes**: the product's own logs — `AndroidLog.log` (223 KB),
`UserKernel.log`, `UserKernelApi.log` — **all high-entropy ciphertext**.
⇒ Encryption is real, but applied to **its own runtime logs**, not to the guest image.

### 4.8 Virtual root — **Grade C / P2**

Observed inside the guest:

```
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

**Conclusions**:
- The product does **not reimplement a root state machine**; it runs a **Magisk 26.0 stack**.
  ⚠️ **Evidence boundary**: `magisk -v` printing `26.0:MAGISK:R` only establishes that "a
  Magisk 26.0-compatible implementation/binary form is running". **No hash comparison against the
  official build was performed**, so "unmodified official release" cannot be asserted.
- It works because the second seccomp filter rewrites the return values of
  `getuid` / `getresuid` / `capget` to `0` / full capabilities.
  **The host kernel reports the same process as uid=10383, CapEff=0 (P0).**
- The `zygisk_lsposed` module explains the origin of `zygiskd64` / `zygiskd32` / `lspd`.
- Device A has **no usable root path whatsoever**, so guest root cannot be the result of host
  privilege escalation.

### 4.9 Scheduling priority — **Grade A / P0 (controlled experiment)**

Controlled experiment on Device A (background the VM, then restore):

```
                    instance1        entire guest tree (85)
before HOME    →  cpuset:/top-app     cpuset:/top-app    (100%)
after  HOME    →  cpuset:/foreground  cpuset:/top-app    (100%, not one moved)
oom_score_adj:    instance1 = 101     guest tree = 0
```

**The host demoted `instance1` from `top-app` to `foreground`, and none of the 85 guest processes
moved.**

⇒ **Correct mechanism** (corroborated by two independent metrics): guest processes **inherit
`instance1`'s cgroup bucket and `oom_score_adj` at fork time during VM startup** (the user launches
the VM in the foreground, so `instance1` is at `top-app` / `oom 0`), and **any subsequent demotion
of `instance1` by the host has no effect on the already-forked guest processes**.

**Accurate formulation (limited to this experimental window)**: "guest processes acquired, at
startup, a scheduling affiliation **independent of `instance1`'s later state changes**, and retained
`top-app` throughout this foreground/background switching experiment."

> ⚠️ **"Permanently" cannot be inferred.** The experiment covers only a ~6-second window after a
> single HOME switch. Process death/restart, LMKD intervention, Activity lifecycle changes, vendor
> schedulers, task profiles, and cgroup freezer were **not covered**. **Grade U.**

**Unresolved cross-device contradiction (Grade U)**: the same observation on Device B showed the
guest tree **following** `instance1` down from `top-app` to `foreground`. Device B is a
Magisk-Alpha-rooted device where root modules can modify cgroups freely, so Device A's data
prevails — but the cause of the discrepancy is undetermined.

### 4.10 Graphics stack — **Grade B / P1 (attribution correction)**

| Holder | `/dev/kgsl-3d0` | `/dev/ion` | `dmabuf` |
|---|---|---|---|
| Host SurfaceFlinger | 12 fds, **840 mmaps** | 2 | 70 |
| Guest SurfaceFlinger | 1 fd, **322 mmaps** | 2 | 35 |

`kgsl` / `ion` / `dmabuf` are the **default** path for *any* GPU-rendering process on Android, and
the host SF has **far more** mappings than the guest SF. Architecturally there is **no guest kernel
at all**, so all guest device access necessarily lands on host kernel drivers.
⇒ "Direct physical-GPU passthrough" is **an architectural necessity, not a design choice**, and
should not be listed as a standalone technical barrier. What is actually worth documenting is the
channel naming in §4.6.

### 4.11 In-process ELF loading — **Grade B / P1**

- Guest processes are produced by `exec`-ing `libloader64.so` / `libloader32.so` from the host app
  directory. `[REDACTED] -l` shows `INTERP = /system/bin/linker64` and entry point `[REDACTED]` — i.e.
  **ELF executables disguised as `.so` files** shipped in the APK (exploiting the fact that
  `lib/<abi>/` files are installed with the executable bit, sidestepping the "unknown-app install"
  restriction). Cross-check (P0): the `Name` field in `/proc/<pid>/status` is literally
  `libloader64.so`.
- `libloader64.so` (200 KB) is an **in-process ELF loader**: its string table contains
  `"%s" is too small to be an ELF executable`, `%s: load executable not supported!`, `execv`.
- `libuserkernel64.so` (4.17 MB) is the **userspace kernel**: of its 279 dynamic symbols,
  **268 are UND (imports) and 0 are defined/exported functions**. It **imports** `open`, `openat`,
  `stat`, `mmap`, `ioctl`, `socket`, `execve` and other real libc calls, yet exports nothing.
  Its string table contains `vma:%u, dentry:%u, inode:%u, file:%u` (**userspace VFS object model**),
  `%s/titan-memfd-inode-%lu`, `%s/titan-tmp-inode-%lu`, `fscache.bin`, `sys_memfd_create`.

> All three items above (`INTERP`, symbol-table statistics, string tables) were obtained at the
> **P1** tier, because `/data/app/*/<pkg>*/lib/arm64/` is `Permission denied` without root.
> The fact that `libloader64.so` is an executable is independently corroborated at **P0** by the
> process `Name` field.

---

## 5. Architecture Model

### 5.0 The essence: three request-handling paths

**This is the single most important section for understanding the product, and the most fundamental
way in which it differs from a true LibOS.**

> **Terminology note (important)**: A / B / C describe **"request / object-access handling
> paths"**, **not "syscall types"**. An object such as `/proc/cpuinfo` is accessed through several
> syscalls — `openat()` → `read()` — where `openat` takes path C and `read` takes path B.
> Saying "cpuinfo is a branch-B syscall" would be inaccurate.

For every **request / object access** from the guest, the L0/L1 interception layer makes a routing
decision. In terms of **externally observable behaviour**, there are three handling paths:

| Path | Behaviour | Reaches the host kernel? | Typical requests | Evidence grade |
|---|---|---|---|---|
| **A · Passthrough** | Handed verbatim to the host kernel | ✅ yes (arguments unchanged) | `mmap`, `futex`, `nanosleep`, `clock_gettime`, `getrandom` | **A′ (inferred)** |
| **B · Synthesis** | Never enters the kernel; L1 constructs the return value in userspace | ❌ no | identity calls `getuid`/`getresuid`/`getpid`/`capget`; and the **read results** of `/proc/{status,cpuinfo,meminfo,version,uptime}` | **Grade C (measured)** |
| **C · Redirection** | Arguments (path / offset) rewritten, then handed to the host kernel | ✅ yes (arguments rewritten) | `openat("/system/…")`, `stat`, the **presentation layer** of `/proc/<pid>/maps` | **Grade C (measured)** |

**A and C both reach the host kernel — the only difference is whether the arguments were rewritten.
B never reaches the kernel at all.** This distinction is more fundamental than "userspace or not":
all three are decided in userspace, but only B is *genuinely* virtual.

#### Evidence

**Branch B — measured (Grade C / P2 versus P0)**

One process, two contradictory self-descriptions, with the host kernel playing no part in the read:

| Observation | Guest view (P2) | Host kernel truth (P0) |
|---|---|---|
| `su -c id` | `uid=0(root)` | uid **10383** |
| `CapEff` / `CapPrm` | `0000003fffffffff` | `0000000000000000` |
| `Seccomp` | **0** | **2** (with 2 filters) |
| `/proc/cpuinfo` | Cortex-A53 × 8 | Snapdragon 8 Gen 2 |
| `/proc/meminfo` | 4,063,232 kB | 15,496,684 kB |

**Branch C — measured (Grade C / P2 versus P1)**

Inside the guest, `/proc/self/maps` reports
`/system/lib64/libnetd_client.so`, dev `03:08`, ino `3080`;
on the host side the very same mapping is
`…/androidfs_10.0.0/system/readonly.bin`, dev `fd:26`, ino `118337`.

⇒ **A real mmap genuinely happened** (real page cache, real zero-copy, pages shared between guest
processes) — **only the presentation layer was rewritten**. This is the **mechanistic basis** for
"a structural advantage on the file-access path" — but it is **not a performance result** (see
"Performance implications" below).

**Branch A — inferred (labelled A′, not directly observed)**

This report **never directly observed the act of passthrough itself**. It is inferred from these
constraints:

1. Guest processes map the **host's** bionic (`/apex/com.android.runtime/lib64/bionic/libc.so`);
2. The guest SF maps the **host's** `/vendor/lib64/vendor.qti.hardware.display.mapper@*.so`;
3. The guest SF holds the **host's** `/dev/kgsl-3d0` (322 mmaps versus the host SF's 840 — the same
   driver path);
4. Architecturally there is no guest kernel, so all device access must land on host kernel drivers;
5. If every syscall were handled in userspace, `libuserkernel64.so` would have to export a complete
   syscall implementation — yet its dynamic symbol table is **279 entries, 268 of them UND and
   0 defined/exported functions**.

⇒ "The overwhelming majority of syscalls land verbatim on the host kernel" is an **architectural
necessity**. But honesty requires stating that **"the filter lets it through" and "the filter
intercepts and immediately forwards it" are externally indistinguishable**, and this report's
instrumentation cannot tell the two apart. Branch A is therefore labelled
**A′ (architecturally inferred, not directly observed)**.

**Candidate branch D — intercept and deny / degrade (Grade U, unproven)**

In theory a further class is needed for calls that must **not** reach the host kernel: `mount`,
`umount`, `ptrace`, `reboot`, `init_module`, `setns`, `unshare`, `chroot`, `pivot_root`.
`libuserkernel64.so` contains constants such as `PTRACE_SEIZE`, `PTRACE_GETREGS`, and
`PR_SET_SECCOMP`, hinting at dedicated handling, but **no direct evidence was obtained**. It is
listed as a **Grade U candidate**.

#### Performance implications (**mechanistic inference, not measurement**)

| Branch | Cost per call |
|---|---|
| A | Native host-kernel path (only Android's own layer-1 seccomp and sandbox checks still apply; **no extra interception overhead**) |
| C | One userspace argument rewrite + native host-kernel path (real page cache / real zero-copy) |
| B | Never enters the kernel; constructed in userspace — *faster* than a real kernel path, but only applicable to identity and hardware-info calls |

> ⚠️ **This report performed no performance measurement whatsoever.** No syscall latency,
> `mmap`/`fork`/`futex`/I-O/GPU benchmark of any kind, and no comparison against a native host
> process. Therefore **conclusions such as "near-native performance" cannot be drawn** — that is a
> claim at an entirely different level.
>
> The evidence supports only a **structural judgment**: **the architecture has the structural
> advantage of reusing host-kernel paths and avoiding the cost of full syscall emulation**, because
> path A goes straight to the kernel and path C only rewrites arguments.
> **This is a mechanistic inference, not a measured performance result.**

#### Positioning conclusion

> **Available observation does not support classifying this as a complete LibOS.**
> A true LibOS / userspace kernel would normally also need to cover syscall semantics, process
> abstraction, virtual-memory abstraction, signal semantics, fd semantics, filesystem semantics,
> networking, scheduling semantics, synchronisation, and IPC in full — yet **this report explicitly
> excludes networking**, and none of the remaining dimensions was verified item by item.
>
> **The evidence better supports** describing it as a
> **hybrid of "host-kernel reuse + syscall projection + userspace filesystem/device abstraction"**,
> i.e. a **syscall projection and device-emulation layer built on top of the host kernel**.

> VPhoneGaGa's technical positioning is not "a userspace kernel reimplementation" but
> **"a syscall projection and device-emulation layer built on top of the host kernel"**.
> Its difficulty lies not in kernel-semantics completeness but in
> (1) the self-consistency of its full-field `/proc` projection,
> (2) ecosystem compatibility with software that depends heavily on kernel behaviour (official
> Magisk above all), and
> (3) adaptation to vendor-specific hardware HALs.

**An intuitive analogy** (for comprehension only, not evidence):
a true LibOS is "building a new house from the ground up, including all plumbing and wiring";
this product is "renting the host's house but swapping out the door number, the utility meters,
and the ID card for those of a different house" — **the walls, pipes, and wiring are still the
host's; it merely looks like a different building from the outside**.

### 5.1 Layered view

```
┌─────────────────────────────────────────────────────────────────────┐
│ Host Linux kernel 5.15.167 (real)                                    │
│   real syscalls · real procfs · real GPU driver · real VMAs          │
└─────────────────────────────────────────────────────────────────────┘
      ▲  ① real syscalls (selectively intercepted by the 2nd seccomp filter)
┌─────┴───────────────────────────────────────────────────────────────┐
│ L0  Second seccomp filter (installed by the guest virtual kernel,    │
│     inherited by all 85 guest processes)                             │
│     → intercepts openat/read on specific paths, returns synthesized  │
├─────────────────────────────────────────────────────────────────────┤
│ L1  Userspace kernel  libuserkernel64.so (4.17 MB, zero exports)     │
│     · userspace VFS object model (vma/dentry/inode/file)             │
│     · virtual PID / UID / capability mapping                         │
│     · /proc content synthesis (→ memfd:titan-tmp-inode-N)            │
│     · @titan-pipe-* peripheral proxy channels                        │
├─────────────────────────────────────────────────────────────────────┤
│ L2  In-process ELF loaders  libloader64.so / libloader32.so (200 KB) │
│     · mmap guest ELFs by offset from readonly.bin, relocate in-proc  │
├─────────────────────────────────────────────────────────────────────┤
│ L3  Guest Android 10 system stack (85 processes)                     │
│     init / zygote64+32 / system_server / surfaceflinger /           │
│     adbd(6556) / Magisk 26.0 / LSPosed / Zygisk64+32 / 141 packages  │
├─────────────────────────────────────────────────────────────────────┤
│ L4  Storage: private plaintext containers (not mounts, not encrypted)│
│     [REDACTED] volume group → [REDACTED] partition superblock → [REDACTED] mmap blocks │
│     system 1.45GiB / vendor 30MB / data + 64MiB fscache / root+boot  │
├─────────────────────────────────────────────────────────────────────┤
│ L5  Host presentation: single MyNativeActivity1 + host SurfaceFlinger│
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 The two-sided table (the report's core evidence)

One process, two self-descriptions:

| Dimension | Guest self-description (P2) | Host kernel fact (P0) | Mechanism |
|---|---|---|---|
| PID | 1 / 43 / 60 / 249 | 7098 / 7227 / 7263 / 7957 | seccomp rewrites the `getpid` family |
| UID | 0 | 10383 | seccomp rewrites the `getuid` family |
| Capability | full `0x3fffffffff` | `0` | seccomp rewrites `capget` |
| Its own seccomp state | 0 | 2 (2 filters) | seccomp rewrites `/proc/self/status` |
| Kernel | 4.14.42-titan | 5.15.167 | synthesized `/proc/version` |
| CPU | Cortex-A53 × 8 | Snapdragon 8 Gen 2 | synthesized `/proc/cpuinfo` |
| Memory | 3.9 GB | 14.8 GB | synthesized `/proc/meminfo` |
| `/system` source | ext4 block device | `readonly.bin` file mappings | synthesized `/proc/mounts` + maps |
| cgroup | `cpu:/apps` | 6 controllers + `/uid_10383/pid_6839` | synthesized `/proc/<pid>/cgroup` |

### 5.3 Startup sequence (observed + inferred)

1. **Host instance bootstrap** — host zygote forks `:instance1`; loads `libVPhoneGaGaLib.so`,
   establishes the JNI channel, opens the `readonly.bin` containers, reads the [REDACTED] superblocks.
2. **Virtual kernel init** — `:instance1` forks `titan64_0:kernel`; that process **installs the
   second seccomp filter on itself**; parses the [REDACTED] index and [REDACTED] superblocks, builds the
   userspace VFS, and mounts the virtual boot partition (`root/block.img`).
3. **Syscall virtualization goes live** — every subsequently forked process inherits the seccomp
   filter and enters "guest" semantics: PID / UID / capability / `/proc` are all projected.
4. **Privileged process spawning** — after the virtual kernel brings up guest init, `magiskd`
   (+0.8 s) / `lspd` (+0.9 s) / `zygiskd64` (+3.0 s) / `zygiskd32` (+6.4 s) appear in sequence, and
   their **real parents on the host side are all the virtual kernel** (the 32-bit chain's real parent
   is the 32-bit virtual kernel).
   **Mechanism undetermined**: this may be direct spawning by the virtual kernel, or the virtual
   kernel acting as a `PR_SET_CHILD_SUBREAPER` that receives orphaned, daemonized descendants —
   see ARCHITECTURE.md §1.3.
   Meanwhile the guest is *projected* a "real-device-shaped" logical parent tree
   (`init(1) → magiskd(43) → {lspd(56), zygiskd64(259)}`) which need not reflect the real parent.
5. **System services and graphics** — `titan64_1:init` parses `init.rc` and brings up ~70 system
   services; the guest SurfaceFlinger hands composited output to the host's single Activity via
   `@titan-pipe-1-framebuffer`; camera / GPS / telephony / sensors / fingerprint / input each use
   their own `@titan-pipe-1-*` channel.
6. **Guest adbd** — listens on 6556 (`android.host.adb.port=6556`), providing an internal debug
   entry point.

### 5.4 Positioning versus gVisor (complexity is not directly comparable)

| Dimension | gVisor (true LibOS) | VPhoneGaGa 3.4.0 |
|---|---|---|
| Syscall handling | **All** intercepted, **all** semantics reimplemented in userspace | **Dispatch**: A passthrough / B synthesis / C redirection (§5.0) |
| Memory management | Own address-space abstraction and page tables (**physical pages still come from host mmap**) | **Fully reuses host VMAs + mmap** |
| CPU scheduling | **Both rely on the host CFS**; gVisor merely emulates scheduling *semantics* (priority, affinity) at the syscall layer, whereas VPhoneGaGa passes even those through | same as left |
| Process isolation | Full sandbox | **No namespaces at all; same UID** |
| What the guest "sees" | An independent kernel abstraction implemented by the sentry | A **path-dispatched synthetic projection** |
| Essence | **"I built a kernel"** | **"I acted out a kernel"** |
| Performance profile (mechanistic) | Userspace handling cost on every syscall | One boundary check plus minor path rewriting (**mechanistic inference; no performance measurement in this report**) |
| Core engineering | Kernel-semantics completeness (network stack, memory, filesystem all self-built) | `/proc` full-field projection consistency + Magisk ecosystem compatibility + device adaptation |

> **This table contains no networking dimension** — see §7 item 10; this report draws no
> networking-architecture conclusions.

> This is **not** to diminish the engineering value: what is genuinely scarce here is
> (1) running a complete Android 10 inside an app sandbox, (2) zero-copy code sharing via a
> plaintext mmap container, and (3) making the official Magisk ecosystem work with zero host
> privileges. But complexity ratings should be stated factually — the two are not on the same axis
> and cannot be ranked against each other.

---

## 6. Corrections

This section proactively lists **overturned or corrected judgments**, including errors made by this
report's own AI-assisted analysis.

| # | Earlier conclusion | Current verdict | Basis | Tier |
|---|---|---|---|---|
| 1 | "[REDACTED] images are decrypted only in memory; no plaintext on disk" | **Overturned** | Plaintext ELF and ARM64 instructions readable at the mapped offsets | P1 |
| 2 | "ext4/f2fs entirely abandoned" | **Corrected** | The upper layer is a private container; the guest is *disguised* as an ext4 block device | P2 |
| 3 | "`androidfs.bin` / `superblock.bin` are core image files" | **Corrected** | They are 64 B / 16 B metadata and superblocks | P1 |
| 4 | Magics written as `[REDACTED]/[REDACTED]/[REDACTED]` | **Supplemented** | Raw on-disk byte order is `[REDACTED]/[REDACTED]/[REDACTED]` (16-bit LE half-words) | P1 |
| 5 | "Four-layer nested **independent** process tree" | **Corrected** | No PID/UTS/USER/IPC namespaces; same UID; "independent" does not hold | P0/P1 |
| 6 | "Host app → virtual kernel" parent-child edge | **Corrected** | They are **siblings** under host zygote; the virtual kernel's parent is `:instance1` | P0 |
| 7 | "Hijacks all guest SVC trap instructions" | **Corrected** | Interception happens at the **seccomp** layer, not at the SVC instruction level; also not ptrace (`TracerPid=0`) | P0 |
| 8 | **【this report's AI error】** "No syscall interception detected" | **Corrected** | The `Seccomp_filters` 1→2 evidence is conclusive | P0 |
| 9 | **【this report's AI error】** "The cpuset claim is refuted" | **Corrected** | The controlled experiment shows the guest tree stays in `top-app` regardless of `instance1` demotion | P0 |
| 10 | "GPU zero-copy passthrough is an SS-tier barrier" | **Attribution corrected** | It is an architectural necessity (no guest kernel) and matches host SF behavior | P1 |
| 11 | "Purely userspace-simulated root state machine" | **Corrected** | What actually runs is a **Magisk 26.0 stack** (`26.0:MAGISK:R`), not a self-built state machine; but **no official-build hash comparison was done**, so it is not called the "official release" | P2 |
| 12 | "Complexity far exceeds gVisor" | **Does not hold** | The two take different routes and are not directly comparable | — |
| 13 | "Runtime logs are fully detached from the host log system" | **Supplemented** | Logs live on **external storage** and are **encrypted** | P1 |
| 14 | "Host SF recognizes only a single rendering window" | **Weakened** | At least 3 host windows coexist; the accurate statement is "guest graphics converge on a single `MyNativeActivity1`" | P0 |
| 15 | `targetSdk=29` never mentioned | **New** | One **important compatibility condition** of the current route (whether it is *necessary* remains unverified) | P0 |
| 16 | `@titan-pipe-*` channels never mentioned | **New** | The real peripheral-proxy mechanism, observable **without root** | P0 |
| 17 | **【added now】** "Magisk/LSPosed/Zygisk are **directly spawned** by the virtual kernel" | **Weakened + mechanism undetermined** | The observed fact is "the real host-side parent is the virtual kernel"; but the PPid shown inside the guest is a **reconstructed logical tree** (`magiskd`→`1` while the truth is `7024`), which points to `PR_SET_CHILD_SUBREAPER` reparenting. See [ARCHITECTURE.md](ARCHITECTURE.md) §1.3 | P0 + P2 |
| 18 | **【added now】** "It is a userspace LibOS / virtual kernel" | **Repositioned** | Changed to **"a syscall projection and device-emulation layer"**: measurement shows only identity/hardware-info calls are synthesized in userspace (branch B), filesystem calls are a **real mmap plus presentation rewriting** (branch C), and everything else **lands verbatim on the host kernel** (branch A). See §5.0 | P0 + P1 + P2 |

### 6.1 This round's absolute-wording audit (tightening the academic phrasing)

This section records a **systematic audit aimed at "strong inferences written as proven facts"**.
No data was changed — only the strength of the conclusions.

| # | Original wording (too strong) | Rewritten as | Reason |
|---|---|---|---|
| 19 | "the second filter **can only** have been installed by the virtual kernel" | "**the evidence best supports** installation by the virtual kernel during bootstrap; **the specific installing caller has not been directly observed**" | Temporal/topological correlation ≠ causal proof; alternative theoretical paths remain |
| 20 | "**hooked per path and reassembled**" | "**highly consistent with an interface/path-level projection model**" | The original asserted an implementation mechanism; observation can only support "consistent with a model" |
| 21 | "memfd **are** the entities behind the fake /proc files" | "only establishes that **anonymous/temporary memory objects are associated with a userspace virtual-file implementation**; highly consistent with the model above" | Exceeds the evidence boundary; correlation ≠ identity |
| 22 | "It is **not** a LibOS" | "**Available observation does not support** classifying it as a complete LibOS; the evidence better supports a hybrid architecture" | A universal negative is unprovable; the report explicitly excludes networking, so it lacks the basis for an exhaustive judgment |
| 23 | "**syscall** three-branch" | "**three request-handling paths**" | An object such as `/proc/cpuinfo` involves both `openat` and `read`, which take different paths; these are not "syscall types" |
| 24 | "**near-native performance**" | "has the **structural advantage of reusing host-kernel paths and avoiding full syscall-emulation cost** (**mechanistic inference**)" | **No performance measurement was performed** (no syscall/mmap/fork/IO/GPU benchmark) |
| 25 | "targetSdk=29 is the **precondition**" | "is **one important compatibility condition** of the current route; whether it is **necessary** is unverified" | No controlled experiment at targetSdk=30/31 |
| 26 | "inherits and **permanently locks** at startup" | "acquires, at startup, a scheduling affiliation **independent of `instance1`'s later changes**, and retains `top-app` throughout this experimental window" | Only one HOME switch over ~6 s was observed; "permanently" is not inferable |
| 27 | "**official** Magisk 26.0" | "**a Magisk 26.0 stack** (`26.0:MAGISK:R`); no official-build hash comparison, so not called the official release" | A version string cannot establish build provenance |

> **Audit principle**: numbers, commands, and raw output are untouched; **only statements claiming
> "already proven" are downgraded to "the evidence best supports"**. It is better for a conclusion
> to look slightly weaker than for the evidence chain to be dismantled over wording.

---

## 7. Limitations

| # | Limitation | Grade |
|---|---|---|
| 1 | The **exact policy** of the second seccomp filter is undetermined (requires reading the BPF program, which is kernel-level information) | **U** |
| 2 | The cgroup inheritance mechanism between `:instance1` and the guest tree **contradicts across the two devices**; unresolved | **U** |
| 3 | Only **one qualified carrier** (Device A); Device B is rooted with a custom ROM and serves only as a control | — |
| 4 | The guest instance is **not factory-fresh** (user-installed LSPosed module and `su_arm64` present) | — |
| 5 | Guest kernel version, CPU model, and memory size are **all disguised values** and cannot support any hardware inference | — |
| 6 | The **semantics of the four 32-bit fields** starting at `readonly.bin` +0x0C are unparsed | **U** |
| 7 | Whether AES is enabled for any partition is unverified (`[REDACTED]` / `AES256CBC` exist, but no evidence of use) | **U** |
| 8 | Version-specific: only 3.4.0 / versionCode 3688. Newer versions may change magics, process rules, or fabricated fields | — |
| 9 | Edge cases (cold boot, crash restart, degraded paths) are not covered | — |
| 10 | **This report contains no networking analysis**; all network-related material has been removed | — |
| 11 | `magiskd` / `lspd` / `zygiskd64` all have the virtual kernel as their real host-side parent; **whether this arises from direct spawning or subreaper reparenting is undetermined** | **U** |
| 12 | The branch policy of the second seccomp filter (passthrough / `USER_NOTIF` / `TRACE`) is undetermined — **"the filter lets it through" and "the filter intercepts and forwards" are externally indistinguishable to this report's instrumentation** | **U** |
| 13 | Whether an "intercept and deny/degrade" branch exists (`mount` / `ptrace` / `setns` / `unshare`) is unproven | **U** |
| 14 | **This report performed no performance measurement whatsoever** (no syscall latency / `mmap` / `fork` / `futex` / I-O / GPU benchmark, no native-host control group), so **no performance conclusion can be drawn** | **U** |
| 15 | Whether `targetSdk=29` is a **necessary** condition for the architecture is unverified (targetSdk=30/31 was not tested) | **U** |
| 16 | Whether the guest's scheduling affiliation changes over long periods or after process restarts is unknown — **only a ~6-second window after one HOME switch was observed** | **U** |
| 17 | The **build provenance of the guest's Magisk binary was not hash-verified**; identity with the official release package cannot be asserted | **U** |
| 18 | The **complete field set of the guest's `/proc` projection is unknown** — only 15 paths were verified to differ across the two views, which is not the same as "only these are replaced" | **U** |

---

## 8. Reproduction Commands

> Each block is annotated with the required permission tier. **P1 blocks can only be run on
> comparison Device B.**

```bash
H=127.0.0.1:5555      # host (stock OnePlus, unrooted)
G=127.0.0.1:6556      # guest (tap "Allow USB debugging" inside the VM)
R=192.168.10.3:5555   # comparison host (Redmi K30, rooted) — P1 blocks only

# ═══════════ P0: reproducible without root ═══════════

# ── Carrier eligibility ──
adb -s $H shell 'command -v su; echo rc=$?'
adb -s $H shell 'ls /system/bin/su /debug_ramdisk 2>&1'
adb -s $H shell getprop | grep -E 'flavor|build.type|verifiedboot|flash.locked'
adb -s $H shell pm list packages | grep -iE 'magisk|kernelsu|lsposed'

# ── Software version ──
adb -s $H shell dumpsys package com.vphonegaga.titan | grep -E 'versionName|versionCode|targetSdk'

# ── Topology and privileged spawning ──
adb -s $H shell ps -A -o PID,PPID,USER,NAME | grep -E 'titan(32|64)_'
adb -s $H shell 'for p in $(ps -A -o PID,NAME | grep -E "titan(32|64)_" | awk "{print \$1}"); \
  do printf "%s %s %s\n" $p $(awk "/^Uid/{print \$2}" /proc/$p/status) \
  $(awk "/^CapEff/{print \$2}" /proc/$p/status); done' | awk '{print $2,$3}' | sort | uniq -c

# ── ★ seccomp layering (core evidence) ──
echo "host control:"
adb -s $H shell "cat /proc/$(adb -s $H shell pidof com.android.systemui)/status" | grep Seccomp
echo "entire guest tree:"
adb -s $H shell 'for p in $(ps -A -o PID,NAME|grep -E "titan(32|64)_"|awk "{print \$1}"); \
  do awk "/^Seccomp/{print}" /proc/$p/status; done' | sort | uniq -c
# expect: host 1 filter; every guest process 2

# ── Scheduling-tier controlled experiment ──
for P in <APP> <INSTANCE1> <KERNEL>; do
  printf "%-8s " $P; adb -s $H shell "grep cpuset /proc/$P/cgroup"
  echo "         oom=$(adb -s $H shell cat /proc/$P/oom_score_adj)"
done
adb -s $H shell input keyevent KEYCODE_HOME      # background (interrupts the VM foreground)
sleep 6
# repeat the loop above → observe whether the guest tree follows instance1
adb -s $H shell am start -n com.vphonegaga.titan/com.vphonegaga.titan.MyNativeActivity1  # restore

# ── ★ Peripheral proxy channel enumeration (no root needed) ──
adb -s $H shell cat /proc/net/unix | grep -oE '@titan-pipe-1-[a-zA-Z0-9:=]*' | sort -u
adb -s $H shell cat /proc/net/unix | grep -c '@titan-process-worker-server'

# ── Permission boundary confirmation (why root is required for some items) ──
adb -s $H shell 'readlink /proc/<PID>/exe'   # empty output
adb -s $H shell 'ls /proc/<PID>/ns'          # Permission denied
adb -s $H shell 'head -1 /proc/<PID>/maps'   # Permission denied
adb -s $H shell 'ls /proc/<PID>/fd'          # Permission denied
adb -s $H shell 'ls /data/data/com.vphonegaga.titan'   # Permission denied
adb -s $H shell 'ls /data/app/*/com.vphonegaga.titan*/lib/arm64'  # Permission denied


# ═══════════ P1: requires host root (comparison Device R only) ═══════════

# ── Namespaces (proving no isolation) ──
adb -s $R shell "su -c 'ls /proc/<PID>/ns/; grep -c NSpid /proc/<PID>/status'"

# ── Real executable ──
adb -s $R shell "su -c 'readlink /proc/<PID>/exe'"

# ── Storage container format (both byte orders) ──
B=/data/data/com.vphonegaga.titan/files/instance1/androidfs_10.0.0
adb -s $R shell "su -c 'od -A d -t x1 -N 32 $B/system/readonly.bin'"   # 41 54 49 54 = [REDACTED]
adb -s $R shell "su -c 'od -A d -t x1 $B/system/superblock.bin'"       # 42 50 55 53 = [REDACTED]
adb -s $R shell "su -c 'od -A d -t x1 -N 32 $B/androidfs.bin'"         # 53 46 44 41 = [REDACTED]
adb -s $R shell "su -c 'od -A d -t x1 -N 64 $B/root/block.img'"        # 41 4e 44 52 4f 49 44 21 = [REDACTED]
adb -s $R shell "su -c 'od -x -N 32 $B/system/readonly.bin'"           # 5441 5449 = [REDACTED] (od -x view)

# ── Mappings and descriptors ──
adb -s $R shell "su -c 'grep readonly.bin /proc/<PID>/maps | head'"    # verify real mmap
adb -s $R shell "su -c 'ls -l /proc/<PID>/fd | grep -oE \"memfd:[^ ]*\" | sort -u'"
adb -s $R shell "su -c 'ls -l /proc/<PID>/fd | grep -oE \"(/dev|/dmabuf)[^ ]*\" | sort | uniq -c'"

# ── APK component metadata (no instruction analysis) ──
L=/data/app/*/com.vphonegaga.titan*/lib/arm64
adb -s $R shell "su -c '[REDACTED] -lW $L/libloader64.so | head -20'"     # INTERP=/system/bin/linker64
adb -s $R shell "su -c '[REDACTED] --[REDACTED] -W $L/libuserkernel64.so | awk \"{print \\\$7}\" | sort | uniq -c'"
adb -s $R shell "su -c 'strings -a $L/libuserkernel64.so | grep -E \"titan-|vma:|fscache\" | sort -u'"
adb -s $R shell "su -c 'strings -a $L/libp7zip.so | grep -E \"^7z|LZMA|AES|BCJ\" | sort -u'"

# ── Log ciphertext verification ──
adb -s $R shell "su -c 'strings -a /sdcard/Android/data/com.vphonegaga.titan/files/instance1/logs/1/UserKernel.log | head'"


# ═══════════ P2: guest-internal shell ═══════════

# ── ★★ Two-sided comparison (same process, two views) ──
# guest side (projected)
adb -s $G shell 'su -c id'
adb -s $G shell 'cat /proc/self/status | grep -E "Uid|CapEff|Seccomp|NoNewPrivs"'
adb -s $G shell 'cat /proc/cpuinfo | grep "CPU part" | head -2'
adb -s $G shell 'grep MemTotal /proc/meminfo; cat /proc/uptime; cat /proc/version'
# host side (truth) — first map titan64_<virtual PID> to its real host PID with ps
adb -s $H shell ps -A -o PID,NAME | grep -E 'titan64_(1|43|60):'
adb -s $H shell 'cat /proc/<HOST_PID>/status | grep -E "Uid|CapEff|Seccomp|NoNewPrivs"'
adb -s $H shell 'cat /proc/cpuinfo | grep "CPU part" | head -2'
adb -s $H shell 'grep MemTotal /proc/meminfo'

# ── ★ Self-incriminating fabrication check ──
adb -s $G shell 'head -2 /proc/self/mountinfo; head -2 /proc/mounts; mount | head -2'
adb -s $G shell 'ls -l /proc/1/exe; ls -l /proc/self/fd'   # mode bits and fd format
adb -s $G shell 'ls /proc | grep -E "^[0-9]+$" | wc -l; ls /proc | grep -E "^[0-9]+$" | sort -n | tail -1'

# ── Guest root shape ──
adb -s $G shell 'magisk -v; magisk -V; ls -l /sbin/magiskinit'
adb -s $G shell 'su -c "ls -la /data/adb/ /data/adb/modules/"'
```

---

## 9. Publication Guidance

### 9.1 Cleared for publication

- The entire report is **behavioral observation**; nothing was disassembled or decompiled.
  It falls under architecture analysis and interoperability research.
- All observation was performed on owned devices and an owned licensed copy.
- Recommendation: retain the AI-assistance disclosure in §1.1 and the reproduction commands in
  §8 — **this is the primary source of the report's credibility**.

### 9.2 Disclosures that must be retained

1. **AI-assistance disclosure** (§1.1), including the two self-corrections.
2. **The permission-tier table** (§1.2 / §1.3), stating for each conclusion whether it came from
   P0 / P1 / P2. **In particular**: the primary carrier has no P1 tier, so every root-requiring
   observation came from comparison Device B.
3. **Both byte orders of the magics** (`[REDACTED]/[REDACTED]/[REDACTED]` and the raw `[REDACTED]/[REDACTED]/[REDACTED]`).
4. **Environmental confounders** (§2.4): Device A has no usable root but had KernelSU installed;
   Device B is rooted with reset properties whose `getprop` output is untrustworthy.
5. **Evidence grades A/B/C/U on every claim**, and all 10 limitations in §7.

### 9.3 Wording standards

Delete all wording implying bypass, cracking, deception, or defeating protections; replace with
outcome descriptions:

| ❌ Do not write | ✅ Write instead |
|---|---|
| bypasses native detection | the second seccomp filter causes `getuid`/`capget` to return virtual values |
| breaks the single-app process-count limit | the guest tree inherits the `top-app` tier at startup and retains it after host demotion |
| adapts to Android 12+ phantom process killing | guest processes have `oom_score_adj` 0, below their host container process's 101 |
| deceives the host scheduler | guest processes acquire, at startup, a scheduling affiliation independent of `instance1`'s later state changes |

### 9.4 Do not publish

- Any **method for bypassing** the second seccomp filter.
- Any **extraction, offset table, or repacking procedure** for `readonly.bin`.
- Any method to make the **guest adbd skip authentication**.
- Implementation details of the **virtual UID / capability forgery**.
- Paths to **private data readable inside the guest**.

> Principle: **"what was observed" may be published; "how to rewrite it" must not be.**

### 9.5 Incremental value of this report

| Increment | Description |
|---|---|
| **Two-sided table** (§5.2) | Two self-descriptions of one process. Unobtainable by external observation alone — the real moat |
| **`Seccomp_filters` 1→2 layering** (§4.3) | Uses a kernel field never previously cited to turn "syscall interception" from conjecture into a countable, reproducible experiment |
| **Self-incriminating fabrication artifacts** (§4.5) | Proves fabrication using the product's own bugs — stronger than any inference |
| **`@titan-pipe-*` channel enumeration** (§4.6) | The real peripheral-proxy mechanism, obtainable without root |
| **Permission-tier system** (§1.2/§1.3) | Clearly separates unrooted from rooted evidence sources |
| **`targetSdk=29`** (§3) | Identifies an **important compatibility condition** of the current route (no claim that it is necessary) |
| **Corrections table** (§6) | Proactively lists overturned conclusions, including two of this report's own AI-assisted misjudgments |

---

*End of report. Every conclusion is reproducible with the commands in §8 under the same
environment.*
