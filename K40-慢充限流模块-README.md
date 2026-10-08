# Redmi K40 (alioth) 限流慢充方案 — 完整使用文档

适用机型：**Redmi K40 / alioth**（骁龙 870 + pm8150b-charger + bq2597x 电荷泵）
系统：Android 13 / MIUI 14
Root 方案：APatch（Magisk、KernelSU 同样适用）
模块版本：**v3**

---

## 一、这套方案解决什么问题

Redmi K40 原厂 33W 快充峰值时电池端电流约 **4.92A**，实测电池温度 38–42℃，长期如此会明显加速电池老化。

本方案通过直接写入内核充电节点，把最大充电电流限制在 **3A**，实现：

| 指标 | 原厂快充 | 本方案 |
|---|---|---|
| 峰值功率 | ~33W | ~12.4W |
| 电池温度 | 38–42℃ | **30–34℃** |
| 电池端电流 | ~4.9A | 2.8–3.0A |
| 充满耗时 | ~1 小时 | ~1.7 小时 |

降温约 **8–10℃**，代价是充电时间变长。

---

## 二、为什么没用其他方案

| 方案 | 结论 |
|---|---|
| **澎湃OS 系统开关** | K40 是 33W，远低于「快充加速」开关所需的 120W 门槛，系统里**根本没有**关闭快充的入口 |
| **MeowPower（喵力全开）** | 要求 Android 16/17 + libxposed API 102 + 澎湃OS 版安全中心，K40 三项全不满足，且需要 ZygiskNext + LSPosed 三层堆叠，风险高收益低 |
| **turbo-charge（原版 v68）** | 设计目的是「删除温控、追求最快充电」，与降温目标**完全相反**，误刷会让手机更热 |
| **turbo-charge（改良版）** | 方向可用，但默认会 bind mount 屏蔽 487 个温控路径、伪造电池温度，反而拆掉了过热保护；且为黑盒二进制，识别不出 alioth 时无从下手 |
| **ACC** | 功能完整但对 K40 这种 33W 机型属于重型方案，且依赖内核暴露可用 charging switch |

**最终选择**：纯 shell 脚本直接读写 sysfs 节点。零依赖、完全透明、可控性强，且保留系统原有温控（只叠加限流，不屏蔽保护）。

---

## 三、工作原理

### 3.1 核心节点

```
/sys/class/power_supply/battery/constant_charge_current_max
```

这是内核允许的**电池端最大充电电流上限**（单位 μA）。出厂值 `4920000`（4.92A）。写入更小的值即可硬性限制充电电流。

辅助节点（v3 会自动扫描并写入）：

| 节点 | 作用 |
|---|---|
| `battery/constant_charge_current_max` | 电池端电流上限（主） |
| `main/current_max` | 电池侧备用限流节点 |
| `usb/pd_current_max` | USB PD 输入端协商电流 |
| `usb/current_max` | USB 输入端电流上限 |
| `battery/input_suspend` | **停充开关**（0=充电，1=停充） |

### 3.2 三层执行时机

1. **`service.sh`**（late_start 阶段）— 延迟 20 秒写入，启动后台守护
2. **`boot-completed.sh`** — 开机完成后补写一次（小米温控守护进程在此之后才启动，会覆盖节点）
3. **守护循环** — 每 30 秒检查一次，发现被改回就重新写入

### 3.3 安全边界

- 电流写入值 **永远不会超过 `FACTORY_MAX`（4920000）**，配置写错也会被自动钳制
- USB 输入端保持「只降不升」策略，不会抬高输入上限
- 停充逻辑不依赖 `battery/status`（详见 5.4）

---

## 四、安装步骤

### 4.1 安装前准备

1. 确认 APatch 已备份原始 boot 镜像（APatch App 内可查）
2. 手机电量建议在 30%–50%（便于安装后验证）

### 4.2 安装

1. APatch App → **模块** → **安装本地模块**
2. 选择 `K40-慢充限流模块-v3.zip`
3. **重启手机**

### 4.3 安装后验证

```bash
su -c "cat /sys/class/power_supply/battery/constant_charge_current_max"
# 应输出 3000000

su -c "ps -ef | grep slowcharge | grep -v grep"
# 应只有 1 行（守护进程单例）

su -c "tail -10 /data/adb/modules/slowcharge/log.txt"
# 应看到 "OK [BAT] ... -> 3000000 (保持)"
```

---

## 五、配置详解

配置文件：`/data/adb/modules/slowcharge/option.txt`

改完**无需重启**，执行：

```bash
su -c "/data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/service.sh"
```

### 5.1 出厂上限（安全边界）

```ini
FACTORY_MAX=4920000
```

K40 实测出厂值。模块不会写入超过此值的电流。**一般不要改**，除非换了内核或 ROM。

### 5.2 电池端最大充电电流（主要降温手段）

```ini
CURRENT_UA=3000000
```

单位 μA（1A = 1000000）。可在 0 ~ 4920000 之间自由调整。

| 取值 | 实际电流 | 占出厂比例 | 实测温度 |
|---|---|---|---|
| 4000000 | 4.0A | 81% | 36℃+（需同时提高 USB_UA） |
| **3000000** | **3.0A** | **61%** | **30–34℃** ← 当前值 |
| 2000000 | 2.0A | 41% | 27–31℃ |
| 1500000 | 1.5A | 31% | 更低 |
| 1000000 | 1.0A | 20% | 约 4W，极凉 |
| 800000 | 0.8A | 16% | 极凉，但亮屏边用边充可能反而掉电 |

⚠️ **低于 800000 时，若同时亮屏使用手机，可能充不进去甚至掉电。**

### 5.3 USB 输入端最大电流

```ini
USB_UA=1500000
```

限制源头功率。填 `0` 表示不限输入端。

⚠️ **K40 上此项效果有限**：本机真实协商值在 `usb/pd_current_max`（约 1.55A），而 `usb/current_max` 常显示异常假值 `100000`。当前 3A 方案下，输入端 1.55A 与电池端 3.0A 几乎同时到顶，是共同瓶颈。

**想进一步提速**（如到 4A），必须同时提高 `USB_UA`（如 2000000），否则光调 `CURRENT_UA` 无效。

### 5.4 按电量停充

```ini
CHARGE_STOP=80
RESUME_AT=70
```

充到 `CHARGE_STOP` 停止，掉到 `RESUME_AT` 恢复。填 `0` 关闭此功能。

**重要机制说明**：

- 停充开关使用 `input_suspend`（**反极性**：0=充电，1=停充）
- 停充状态下电池是**放电**的（实测约 +230mA），不是完全断开
- 因此会缓慢从 80% 放到 70% 再补回，形成循环 —— **这是迟滞设计的预期行为，不是故障**

⚠️ **K40 上的已知陷阱**：`battery_charging_enabled` 这个节点文件存在、能读能写，但**内核不认**（写 0 后仍在充电），是个假开关。v3 已弃用该节点，改用实测有效的 `input_suspend`。

### 5.5 守护循环

```ini
DAEMON=1
INTERVAL=30
DELAY=20
```

- `DAEMON=0` 则只在开机时写一次，停充功能将不可用
- `INTERVAL` 不宜小于 15
- `DELAY` 是开机后等待充电驱动就绪的时间

---

## 六、验证方法

### 6.1 快速验证（单条命令）

插原装 33W 充电头，电量 30%–60% 时：

```bash
su -c "cat /sys/class/power_supply/battery/constant_charge_current_max; cat /sys/class/power_supply/battery/current_now; cat /sys/class/power_supply/battery/temp"
```

判定：`constant_charge_current_max` = 配置值；`current_now` 绝对值 ≤ 配置值；`temp` 除以 10 应明显低于原厂快充。

### 6.2 完整验证（连续采样）

```bash
sh /sdcard/test_charge.sh 2>&1 | tee /sdcard/charge_result.txt
```

自动采样 10 次（每 20 秒一次，共约 3.5 分钟），输出格式：

```
[1/10] 42% | 33℃ | 2.9A | 4170887 | max=3000000 | Charging | Fast
```

**看 `max=` 那一列**：全程等于配置值 = 完全顶住了厂商覆盖；在配置值与 4920000 之间来回跳 = 守护在正常工作，看平均电流即可。

### 6.3 停充功能验证

不用等充到 80%，临时把阈值调到当前电量以下：

```bash
su -c "sed -i 's/^CHARGE_STOP=.*/CHARGE_STOP=70/;s/^RESUME_AT=.*/RESUME_AT=65/' /data/adb/modules/slowcharge/option.txt && /data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/service.sh"
```

等待 40 秒后：

```bash
su -c "tail -6 /data/adb/modules/slowcharge/log.txt; cat /sys/class/power_supply/battery/status"
```

成功标志：日志出现 `停充: 电量 XX% >= 70%`，`status` 变 `Discharging`。

测完改回原值再跑一次 `service.sh`。

---

## 七、不同场景推荐参数

### 7.1 日常主力机（平衡速度与温度）

```ini
CURRENT_UA=3000000
USB_UA=1500000
CHARGE_STOP=80
RESUME_AT=70
```

充满约 1.7 小时，20%→80% 约 1 小时，温度 30–34℃。**已通过四轮实测验证。**

### 7.2 长期插电的备用机（最优电池保养）

```ini
CURRENT_UA=1000000
USB_UA=1500000
CHARGE_STOP=60
RESUME_AT=45
```

**为什么这样配**：锂电池在一直插电场景下的老化，主要由**日历老化（静置损耗）**主导，而非循环损耗。存放电量越高衰减越快，且是加速的（25℃ 存放一年：100% 电量损失约 20%，75% 损失约 12–15%，50% 仅损失约 4%）。

把区间下移到 45–60%：平均 SOC 约 52%，日历老化接近理论最优；15% 的浅循环损耗极小；拔下来用时仍有 45% 电量。

⚠️ **不建议为此追求旁路供电**：K40 无硬件支持，且旁路状态下电池离线，**充电线被碰掉会立刻关机**——备用机往往正是要在这种时刻顶上。更重要的是，很多旁路实现会把电池停在 100%，日历老化反而比 70–80% 循环更差。

### 7.3 极致降温（不赶时间）

```ini
CURRENT_UA=1500000
USB_UA=1500000
```

### 7.4 临时恢复快充

```ini
CURRENT_UA=4920000
USB_UA=0
```

或直接在 APatch 里禁用模块后重启。

---

## 八、注意事项与故障排查

### 8.1 关于电流读数

**`current_now` 负值 = 充电**（高通平台约定，与常见约定相反）。例如 `-3028318` 表示约 3.0A 正在充入。

**电流偶尔跳到 0.0A 属正常**：bq2597x 电荷泵在 2:1 转换时高速开关，采样刚好落在关断窗口就会读到接近 0。只要 `status` 仍是 `Charging`、电量在涨，就不是问题。

**`usb/current_max` 常显示 `100000` 是假值**，不代表真实协商结果。真实值看 `usb/pd_current_max`。

**`charge_type` 显示 `Fast` 有误导性**：小米此字段判定逻辑较松，2.5W 弱电源下也会显示 Fast，不要以此判断快充状态。判断真快充看 `usb/type`（`USB_PD`/`USB_DCP` = 充电头，`USB` = 电脑口）和 `usb/voltage_now`（9V/11V）。

### 8.2 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| 写入后立刻变回原值 | 旧守护进程仍在运行 | 重启手机（会清掉所有进程），v3 已内置残留清理 |
| 想调高电流但调不上去 | v1/v2 的「只降不升」机制 | 用 v3（改为 `FACTORY_MAX` 边界内自由调整） |
| 多个守护进程并存 | v1 无 pidfile | v3 已用 pidfile + 残留清理修复 |
| 停充不生效 | 用了假开关 `battery_charging_enabled` | v3 已改用 `input_suspend` |
| 停充后再也充不回来 | 旧版依赖 `status` 判断，停充后 status 变 Discharging 导致失联 | v3 改用 `usb/present` 判断，已修复 |
| 拔掉充电器后再插充不进 | 停充开关未复位 | v3 已内置拔出自动复位 |
| 日志全是 `FAIL ... 写入失败` | 执行时机太早或权限问题 | 把 `DELAY` 调到 40 |

### 8.3 使用注意

- **低于 800mA 时亮屏使用可能充不进电**
- **改配置后必须执行 `service.sh`** 或重启才生效
- **重装模块会覆盖 `option.txt`**，装完记得核对配置值
- 模块与 turbo-charge 等其他充电模块**不要同时启用**（会争夺同一批节点）
- 日志超过 300 行会自动截断保留最后 80 行

### 8.4 比软件更有效的物理降温

温度对电池寿命的影响**比电量区间更猛**：同样 40% 电量存放，25℃ 一年损失 4%，40℃ 就要损失 15%。

- 摘掉厚保护壳（可降 4–7℃）
- 别压在枕头下、塞柜子角落、放阳光直射处
- 使用支持 USB-PD PPS 的充电头（电压转换在充电头内完成，手机内几乎不降压）——K40 实测已走 PPS，`usb/type = USB_PD`、电压 8.2–8.6V 动态调整

---

## 九、实测数据记录（alioth / Android 13 / APatch）

### 9.1 限流效果（原装 33W 充电头）

| 测试轮次 | 电量区间 | 上限值 | 温度 | 实际电流 | 功率 |
|---|---|---|---|---|---|
| 1 | 37% | 2000000（零覆盖） | 30–31℃ | 1.8–2.0A | ~7.5W |
| 2 | 64–67% | 3000000（零覆盖） | 32–33℃ | 2.9–3.0A | ~12.4W |
| 3 | 70–73% | 3000000（零覆盖） | 33℃ | 2.8–3.0A | ~12.4W |
| 4 | 78–82% | 3000000（零覆盖） | 34℃ | 2.6–3.0A | ~12.4W |

三轮不同电量区间结果一致，数十次采样中上限值**从未被小米守护进程改回**。

### 9.2 停充开关对比（诊断实测）

| 开关 | 写入测试 | 结论 |
|---|---|---|
| `battery_charging_enabled` = 0 | status 仍 `Charging`，电流 3.0A 照充 | ❌ 假开关，弃用 |
| `input_suspend` = 1 | status 变 `Discharging`，电流反转 | ✅ 有效，采用 |

### 9.3 转换效率

```
输入：1.55A @ 8.29V ≈ 12.9W
输出：3.0A  @ 4.13V ≈ 12.4W
效率：约 96%
```

PPS 让电压转换发生在充电头内，是温度低的主要原因之一。

---

## 十、卸载与还原

### 10.1 临时禁用

APatch App → 模块 → 关闭开关 → 重启。

### 10.2 完全卸载

APatch App → 模块 → 移除 → 重启。

### 10.3 手动还原原始值

模块首次运行时会自动记录原始值到：

```
/data/adb/modules/slowcharge/original.txt
```

如需手动还原，参照该文件内容写回即可：

```bash
su -c "echo 4920000 > /sys/class/power_supply/battery/constant_charge_current_max"
su -c "echo 0 > /sys/class/power_supply/battery/input_suspend"
```

---

## 附：文件清单

| 文件 | 用途 |
|---|---|
| `module.prop` | 模块元信息 |
| `option.txt` | **配置文件**（主要改这里） |
| `common.sh` | 核心逻辑：节点扫描、写入、停充控制 |
| `service.sh` | 开机启动脚本（late_start） |
| `boot-completed.sh` | 开机完成补写 |
| `probe.sh` | 节点探测（初次安装前确认可写性） |
| `test_charge.sh` | 限流效果验证（连续采样 10 次） |
| `stop_diag.sh` | 停充功能诊断 |
| `log.txt` | 运行日志（运行时生成） |
| `original.txt` | 原始值备份（首次运行时生成） |
| `daemon.pid` | 守护进程 PID（运行时生成） |

---

## 快速命令速查

```bash
# 查看当前电流上限
su -c "cat /sys/class/power_supply/battery/constant_charge_current_max"

# 查看实际充电电流（负值=充电）与温度（除以10=℃）
su -c "cat /sys/class/power_supply/battery/current_now; cat /sys/class/power_supply/battery/temp"

# 修改配置后即时生效
su -c "/data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/service.sh"

# 改为 3A / 80-70 停充（日常主力机）
su -c "sed -i 's/^CURRENT_UA=.*/CURRENT_UA=3000000/;s/^CHARGE_STOP=.*/CHARGE_STOP=80/;s/^RESUME_AT=.*/RESUME_AT=70/' /data/adb/modules/slowcharge/option.txt && /data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/service.sh"

# 改为 1A / 60-45 停充（长期插电备用机）
su -c "sed -i 's/^CURRENT_UA=.*/CURRENT_UA=1000000/;s/^CHARGE_STOP=.*/CHARGE_STOP=60/;s/^RESUME_AT=.*/RESUME_AT=45/' /data/adb/modules/slowcharge/option.txt && /data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/service.sh"

# 查看日志
su -c "tail -20 /data/adb/modules/slowcharge/log.txt"

# 确认守护进程只有一个
su -c "ps -ef | grep slowcharge | grep -v grep"
```
