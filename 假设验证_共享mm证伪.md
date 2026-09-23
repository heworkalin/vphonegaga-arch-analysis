# 假设验证记录：外部 AI「共享 mm_struct / 信号隔离」模型 —— 证伪

| 项目 | 内容 |
|---|---|
| 记录日期 | 2026-09-23 |
| 验证对象 | 由**另一个 AI** 给出的技术分析（外部报告，非本系列产出） |
| 被审假设 | 产品用 `clone(CLONE_VM)`（不含 `CLONE_THREAD`）创建大量**共享同一 `mm_struct`** 的独立线程组，靠 `prctl(PR_SET_DUMPABLE,0)` 实现**跨 tgid 信号隔离黑科技** |
| 验证载体 | OnePlus PJE110（宿主 Android 15，**无可用 root**）+ 其内置客户机实例 |
| 方法 | 提出**可证伪判据** → 实机采集 → 逐条判定 |
| 结论 | **核心断言被证伪**；部分观测正确但被错误归因 |

> **定位**：本文件不是"反驳某方权威"，而是记录一次**假设—判据—实测—判定**的完整流程。
> 它展示 **K1/K2/K3 分层**的意义：听起来自洽的机制模型，必须能被证据杀死。

---

## 1. 被审阅的外部 AI 分析（原文要点）

| # | 断言 |
|---|---|
| A1 | `libloader64` 反复 `clone(CLONE_VM \| CLONE_SIGHAND \| CLONE_FS \| CLONE_FILES \| CLONE_IO)`，**不带 `CLONE_THREAD`**，产生大量全新 tgid |
| A2 | 这些互相独立的线程组**共享同一个 `mm_struct`**（多 tgid 共用一个 mm） |
| A3 | `prctl(PR_SET_DUMPABLE,0)` 作用于 **`mm_struct`**，所以任一线程组置 0 ⇒ **全体 dumpable=0** |
| A4 | 因此跨 tgid 的 `kill -9` 走 **`ptrace_access_check()`**，读 `mm->dumpable=0` ⇒ 返回 **EPERM**（即使 root / 有 `CAP_KILL`） |
| A5 | `CoreDumping=0` 是这套**独有反调试机制**的体现 |
| A6 | `PID 1450(main)` 是 **Magisk zygiskd** 宿主进程 |
| A7 | 这是市面其他虚拟机没有的"核心黑科技" |

---

## 2. 验证判据（可证伪）

| 假设 | 判据 | 理由 |
|---|---|---|
| **A2 共享 mm** | 比较各进程的 **`VmSize`** | `/proc/<pid>/status` 的 `VmSize` 取自 **`mm->total_vm`**，是 **`mm_struct` 的属性**。若两个任务共享同一 mm，其 `VmSize` **必须完全相同**。 |
| **A4 kill 机制** | 核对内核 `kill()` 路径 | 看它到底调用哪个函数 |
| **A5 CoreDumping 特殊性** | 对比**普通 Android APP** | 若普通 APP 也是 0，则非特殊机制 |
| **A6 1450 身份** | 读 `/proc/1450/cmdline` | 直接看可执行体 |

---

## 3. 实测结果

### 3.1 ★ 决定性判据：`VmSize`

```
PID    Name              Tgid    Threads  VmSize(kB)   CoreDumping
3968   phonegaga.titan   3968     83      10381064       0
4645   titan:instance1   4645     93      10962564       0
4928   libloader64.so    4928     16       2903664       0
4986   libloader64.so    4986      2       3047760       0
4998   libloader64.so    4998      2       3051196       0
4967   libloader32.so    4967      1        471960       0
5134   libloader64.so    5134      2       5147128       0
5189   libloader64.so    5189      4       5221220       0
```

**`VmSize` 从 471,960 kB 到 10,962,564 kB，全部不同。**
⇒ 若它们共享同一 `mm_struct`，这些值**必须相同**。
⇒ **A2 被证伪：各进程拥有各自独立的 `mm_struct`。**

### 3.2 `CoreDumping=0` 的普遍性

```
3968  phonegaga.titan      uid=10383  CoreDumping=0
8991  com.oplus.dmp:main   uid=10142  CoreDumping=0
13369 ...iflows_main       uid=10165  CoreDumping=0
```

普通 Android 应用进程同样是 `CoreDumping=0`。
⇒ **A5 被证伪**：这是 APP 启动时降 uid 触发 `set_dumpable()` 的**正常结果**，不是产品独有的反调试手法。

### 3.3 1450 的真实身份

```
/proc/1450/cmdline  →  zygote64
Name: main   PPid: 1   Uid: 0   CapEff: 000001ffffffffff   Seccomp: 0
```

⇒ **A6 认错**：1450 是**宿主 `zygote64`**（`Name` 显示 `main` 是 zygote 改了 comm 名）。
本设备**宿主没有 Magisk** —— `magiskd` / `zygiskd` 只作为**客户机进程**存在
（如 `titan64_43:magiskd`，父进程是 4928）。

### 3.4 kill 的内核路径

```
sys_kill
 └─ kill_pid_info
     └─ group_send_sig_info
         └─ check_kill_permission
             ├─ kill_ok_by_cred()      ← 凭据判定（uid / CAP_KILL）
             └─ security_task_kill()   ← LSM（Android 上是 SELinux）
```

**`kill()` 路径不调用 `ptrace_access_check()`，也不读 `mm->dumpable`。**
`mm->dumpable` 影响的是 ptrace / `/proc/<pid>/{mem,environ}` / `process_vm_readv` 一类的访问，
**与信号投递无关**。

⇒ **A4 机制错误**：`dumpable=0` 不能解释 `kill` 的 EPERM。

---

## 4. 逐条判定

| # | 外部 AI 断言 | 判定 | 依据 |
|---|---|---|---|
| A1 | 用 `clone` 创建大量独立 tgid | **观测正确**（但见 A2） | `Tgid == Pid`，进程数众多 |
| A2 | 多 tgid **共享同一 `mm_struct`** | ❌ **证伪** | `VmSize` 全不同（471,960 ~ 10,962,564 kB） |
| A3 | dumpable 存于 mm ⇒ 全局生效 | ❌ **前提不成立** | 前提（共享 mm）已证伪 |
| A4 | kill EPERM 源于 `ptrace_access_check` | ❌ **机制错误** | kill 路径不含该函数，不读 `mm->dumpable` |
| A5 | `CoreDumping=0` 是独有反调试机制 | ❌ **证伪** | 普通 APP 同样是 0 |
| A6 | 1450 = Magisk zygiskd | ❌ **认错** | `cmdline = zygote64`；宿主无 Magisk |
| A7 | 是"核心黑科技" | ⚠️ **不成立** | 其观测可被普通 Android 行为解释，机制部分错误 |

---

## 5. 实测支持的图景（与本系列其余证据一致）

| 机制 | 状态 |
|---|---|
| 客户机任务是**普通独立进程**（各自 mm、`Tgid == Pid`） | ✅ K1 |
| 第二层 seccomp 过滤器 | ✅ K1（`Seccomp_filters` 1→2） |
| 身份投影（虚拟 uid / capability） | ✅ K1（两侧对照） |
| `CoreDumping=0` | ✅ 但为 **Android APP 的正常状态**，非特殊 |
| 共享 `mm_struct` | ❌ **证伪** |

> **隔离来源**是 seccomp + 身份投影 + SELinux + 系统本身的非 dumpable 状态，
> **不是**"共享 mm 的 dumpable 全局传播"。

---

## 6. 未验证项（诚实边界）

- **宿主 `root + CAP_KILL` 下能否 `kill -9` 这些进程**：本设备宿主**无 root**，无法测试。
  - 我只能以 `uid=2000` 测试，结果自然是 EPERM（凭据不匹配）：

    ```
    kill -9 4928 → Operation not permitted
    kill -9 4986 → Operation not permitted
    kill -9 4645 → Operation not permitted
    ```

  - ⚠️ 若在有 root 的设备上确实观察到 EPERM，更可能的成因是
    **SELinux `security_task_kill()`**，而**不是** `mm->dumpable`。
- 本记录只针对**本设备/本版本**；不排除其他版本使用其他实现。

---

## 7. 方法论价值

本次验证演示了一条完整链路：

```
可证伪假设
   ↓
设计判据（共享 mm ⇒ VmSize 必须相同）
   ↓
实机采集
   ↓
判定：证伪
```

**为什么重要**：A2/A3/A4 三段串起来自洽、术语专业、读起来很像"逆向实锤"，
但**只要设计一个判据就能杀死它**。这正是本系列坚持 **K1 / K2 / K3** 分层的原因：

> 外部可观测行为能够约束内部架构，但通常不能唯一确定内部实现；
> 一个"听起来很对"的机制模型，在降级为 K2/K3 之前，必须经过判据检验。

---

## 8. 复现命令

```bash
H=127.0.0.1:5555

# 判据一：共享 mm ⇒ VmSize 必须相同
adb -s $H shell 'for p in $(ps -A -o PID,NAME | grep -E "titan(64|32)_" | awk "{print \$1}" | head -14); do
  s=$(cat /proc/$p/status 2>/dev/null)
  printf "PID=%-7s Tgid=%-7s Thr=%-3s VmSize=%-10s CoreDump=%s\n" $p \
    "$(echo "$s"|awk "/^Tgid:/{print \$2}")" \
    "$(echo "$s"|awk "/^Threads:/{print \$2}")" \
    "$(echo "$s"|awk "/^VmSize:/{print \$2}")" \
    "$(echo "$s"|awk "/^CoreDumping:/{print \$2}")"
done'

# 判据二：CoreDumping=0 是否普通 APP 也有
adb -s $H shell 'for p in 3968 8991 13369; do
  cat /proc/$p/status 2>/dev/null | awk -v p=$p "/^(Name|Uid|CoreDumping):/{printf \"%s \", \$2} END{print \"PID=\"p}"
done'

# 判据三：1450 身份
adb -s $H shell 'cat /proc/1450/cmdline | tr "\0" " "; echo'
adb -s $H shell 'ps -A -o PID,PPID,NAME | grep -iE "magisk|zygisk"'
```

---

*记录结束。被审阅的外部 AI 分析中，观测层部分正确，机制层核心断言（A2/A3/A4）被实测证伪。*
