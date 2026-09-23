# VPhoneGaGa Architecture Overview (one-minute read)

[中文](./架构速览.md)

| Item | Content |
|---|---|
| Purpose | **Quick understanding**: what this repository says, what the idea is, and where it is strong or weak |
| Nature | ⚠️ **Conjectural summary (K2/K3)** — a **candidate model** based on public information and black-box observation; **it does not represent the product's real implementation** |
| Detailed version | [`README.md`](README.md) §5 Architecture Model · [`垫片分层模型_进程与线程.md`](垫片分层模型_进程与线程.md) |
| License | [`LICENSE`](LICENSE) (MIT) |

---

## One sentence

> **It did not "build a kernel", and it is not "a syscall hook"; it is:**
> **splitting an Android into many modules that each do the least work, then stitching them back into one unified system with a shim layer.**

---

## Three core ideas (conjectural)

| # | Idea | In one line |
|---|---|---|
| **1** | **Multi-process carriers** | Every guest process is a **real host process**; guest threads are host threads |
| **2** | **Boundary interception** | A **2nd seccomp filter** is the interception boundary: **default pass-through, selective interception** |
| **3** | **Semantic triage** | Each request is routed three ways: **synthesize it / maintain it / borrow it** |

---

## Three processing paths (the core model of this report)

| Path | Meaning | Typical objects | Determinacy |
|---|---|---|---|
| **A · borrow from host** | Behavior directly reuses the host kernel | `mmap` · `clock` · socket data plane · GPU | K1 object exists / K2 processing location |
| **B · synthesize** | Return values constructed in userspace | identity (`uid`/`cap`) · `uname` · `/proc` content | K1 result / K3 mechanism |
| **C · maintain** | State held in userspace | mount tree · VFS · `/proc/net/*` · fd view | K1 result / K2 mechanism |

> **Design rule**: never implement what can be borrowed (saves performance); never miss what must be "acted out" (protects correctness).

---

## Structure diagram

```text
                Guest Android
                      │
          multiple real Host carriers (processes/threads)
                      │
                      ▼
            ┌──────────────────┐
            │ Per-process shim │   ← capture + answer locally when possible
            └────────┬─────────┘
                     │
              fast path (default pass-through)
              /                    \
         Host side               Broker side
      (real resources)        (semantic state)
         mmap / VMA               vPID / uid / cap
         CFS scheduling           /proc view
         GPU / socket             mount tree
              \                    /
               └────────┬─────────┘
                        ▼
              one unified Guest world
```

---

## Strengths (conjectural)

| # | Strength | Why |
|---|---|---|
| 1 | **Data plane close to native** | `mmap` / page cache / scheduling / GPU / socket are all **borrowed from the host**, not rewritten |
| 2 | **No privileges required** | Implemented purely inside an app sandbox — **no root, no kernel module** |
| 3 | **Compatible with the real ecosystem** | It runs the **stock Android userspace** and the **Magisk stack**, not a home-made subset |
| 4 | **Looks like one device** | Identity, system info, mounts, `/proc` are all projected into a "nonexistent real phone" |
| 5 | **Threads need no emulation** | Guest threads are host threads — **no userspace thread scheduler needed** |
| 6 | **Decoupled modules** | Each module does the least work; clear responsibility, independently evolvable |

---

## Costs and weaknesses (conjectural)

| # | Cost / weakness | Why |
|---|---|---|
| 1 | **Cross-process consistency is hardest** | The view is spread across processes and must stay consistent at all times (**the main effort and risk**) |
| 2 | **Projection maintenance is expensive** | `/proc` must be self-consistent field by field, with no contradictions across interfaces (**the product itself slips up**) |
| 3 | **Version fragility** | Version dependencies on external components such as Magisk; upgrades may break it |
| 4 | **Performance has a ceiling** | Once the interception rate rises, it degrades toward "every call traps into userspace" |
| 5 | **Isolation relies on userspace semantics** | No namespaces, same uid; isolation correctness rests on its own implementation |
| 6 | **Hard to debug** | All logic sits in the userspace projection layer; faults are hard to locate |
| 7 | **High adaptation cost** | Graphics/peripherals must bind to host vendor HALs — **linear per-device growth** |
| 8 | **"Unity" is the most expensive part** | The appearance of unity is cheapest; maintaining unity is costliest |

---

## What it resembles, and what it does not

| | Resembles | Does not resemble |
|---|---|---|
| Comparison | **distributed shims + central coordination** | single-process LibOS (gVisor) · namespace container (Docker) |
| Reason | multi-process + full semantic shim | the former is one address space; the latter goes straight to the kernel |
| In one line | externally, it **"acts out" a kernel** | it is not **"building"** one |

---

## Suggested reading order

1. **This file (overview)** — understand the idea and its trade-offs in one minute
2. [`README.md`](README.md) §5 — architecture model and determinacy layering (K1/K2/K3)
3. [`垫片分层模型_进程与线程.md`](垫片分层模型_进程与线程.md) — how processes/threads are layered
4. [`假设验证_共享mm证伪.md`](假设验证_共享mm证伪.md) — methodology demo (hypothesis → criterion → falsification)
5. [`复现路线与垫片设计.md`](复现路线与垫片设计.md) — how one would build something similar
6. [`P1_归档_结构性观测.md`](P1_归档_结构性观测.md) — structural observations from the higher-privilege layer

---

## Boundaries

All architecture conclusions are split into three levels: **【K1】** measured fact · **【K2/K3】** inference / indistinguishable · **【suggestion】** design opinion.
This file is a conjectural summary; for details and evidence see [`README.md`](README.md).

---

*End of overview. This is a conjectural summary; for details and evidence see [`README.md`](README.md).*
