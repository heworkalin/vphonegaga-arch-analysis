# 启动日志·四状态对照

来源：`sh.sh` 在宿主侧每 0.3 秒执行 `ps -ef | grep titan` 的采样。

| 文件 | 时间 | 状态 | Magisk 进程 | 组件数 | netd vpid |
|---|---|---|---|---|---|
| `2335_magisk-on.txt` | 23:35 | **Magisk 打开** | `magisk`+`magiskd`×4+`busybox`+`sh`×6+`lspd`+`zygiskd`×2 | 117 | 60 |
| `2338_magisk-off_boot未重置.txt` | 23:38 | **Magisk 关闭（boot 未重置）** | `magiskd`×2+`lspd`+`zygiskd`×2+`resetprop`（**残留**） | 115 | 60 |
| `2345_boot已重置.txt` | 23:45 | **重置 boot 后** | **0** | 102 | 42 |
| `2348_打开boot未安装任何.txt` | 23:48 | **打开 boot，未安装任何** | **0** | 96 | 42 |

## 关键结论

1. **“重置 boot” ≡ “打开 boot 未安装任何”**：两者 vpid 布局逐项一致，都是无 Magisk 的干净状态。
2. **Magisk 层插入点固定**：始终在 `apexd` 之后、`netd` 之前。
3. **vpid 编号随 Magisk 注入整体偏移**：`netd` 60↔42、`zygote64` 61↔43、`zygote` 62↔44。
4. **产品自带 `su` 四状态恒在**（由客户机 `init` 拉起，有独立开关）⇒ root 通道自建，Magisk 只是叠加。
5. **未重置 boot 时残留补丁仍会旁路拉起 `magiskd`**（父进程为虚拟内核而非 init）。

## 复现命令

```bash
# sh.sh 内容：宿主侧轮询
while true; do adb -s 127.0.0.1:5555 shell ps -ef | grep titan >> process_log.txt; sleep 0.3; done
```

详见 [`../README.md`](../README.md) §4.14 与 [`../复现路线与垫片设计.md`](../复现路线与垫片设计.md)。
