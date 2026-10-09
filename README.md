# Slow Charge 限流慢充 v4.1

适用于 **Redmi K40（alioth）** 的充电限流模块，运行在 **APatch** 下。

降低快充功率以减少发热，并按电量区间控制充电，减缓电池老化。

---

## 目录

1. [快速上手](#一快速上手)
2. [它解决什么问题](#二它解决什么问题)
3. [核心原理：为什么 v3 会失效](#三核心原理为什么-v3-会失效)
4. [v4 / v4.1 做了什么改进](#四v4--v41-做了什么改进)
5. [配置文件详解](#五配置文件详解)
6. [文件结构](#六文件结构)
7. [实测数据](#七实测数据)
8. [节点探测结论](#八节点探测结论)
9. [单位换算](#九单位换算)
10. [验证方法](#十验证方法)
11. [故障排查](#十一故障排查)
12. [已知限制](#十二已知限制)
13. [版本历史](#十三版本历史)

---

## 一、快速上手

### 安装

```
APatch → 模块 → 安装本地模块 → 选择 K40-慢充限流模块-v4.1.zip → 重启
```

> 如果之前装过 v3/v4，建议**先移除再装 v4.1**。两者 `id` 相同（都是 `slowcharge`），
> 覆盖安装可能残留旧文件（如 `daemon.pid`、旧日志），导致诡异问题。

### 改配置（无需重启）

```bash
su -c "/data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/service.sh"
```

### 卸载

APatch 里移除模块并重启。模块会在首次运行时把原始值记录到
`/data/adb/modules/slowcharge/original.txt`，需要完全还原可参照该文件手动写回。

---

## 二、它解决什么问题

### 问题 1：快充发热

K40 原厂 33W（4.92A / 11V PPS），充电时温度 38–42℃。

限流到 3A 后：功率降到约 12.4W，温度降到 **31–33℃**。

### 问题 2：长期插电导致电池老化

锂电池老化主要由**日历老化（静置损耗）**主导，存放电量越高衰减越快：

| 静置电量 | 25℃ 存放一年容量损失 |
|---|---|
| 100% | 约 20% |
| 92% | 约 18% |
| 75% | 约 12–15% |
| **50%** | **约 4%** |

所以备用机理想的电量区间是 **45–60%**（平均 SOC 约 52%）。

---

## 三、核心原理：为什么 v3 会失效

这是理解 v4 的关键，也是整个方案演进的主线。

### v3 的失效链条

v3 用 `input_suspend=1` **硬停充**。从日志时间线可以清楚看到问题：

```
08:53:54  停充: 电量 87% >= 80%
          （中间 14.5 小时，一条日志都没有）
23:24:33  恢复: 电量 70% <= 70%
23:32:51  停充: 电量 80% >= 80%
早上       电量 100%        ← 失控
```

14.5 小时的日志空白，是 Android **Doze（深度休眠）** 的典型特征。完整因果链：

```
input_suspend = 1
  → battery/status 变成 Discharging
  → Android 判定"设备在用电池、未接电源"
  → 满足 Doze 前置条件（插着电是不进 Doze 的）
  → 进入深度休眠，CPU 挂起
  → 脚本里的 sleep 30 不再推进
  → 守护被冻结数小时
  → 期间没人监督，input_suspend 被系统充电守护进程清掉
  → 充电器实际还插着 → 一路充到 100%
```

**注意对比**：`23:24 → 23:32` 那 8 分钟日志很密集，因为那时在充电、
status 是 Charging、Android 不进 Doze、守护正常跑。

所以失效不是随机的，**只在停充期间发生**。

### v4 的解法：软停充（trickle）

症结在于 `status=Discharging`。那么反过来想：

> **如果让 status 始终保持 Charging，Android 就不会进 Doze。**

v4 因此改为：到阈值时**不断开充电，只把电流降到极小值**。

```
input_suspend=1        → status=Discharging → 进 Doze  ❌
constant_charge_current_max=60000 → status=Charging  → 不进 Doze ✅
```

这样守护永不冻结，**从根本上绕开了 Doze，连 wakelock 都不需要**（零额外耗电）。

而 `constant_charge_current_max` 在四轮测试中**从未被小米守护进程覆盖**，
是本方案最可靠的节点——软停充正好复用了这个可靠性。

---

## 四、v4 / v4.1 做了什么改进

### v4 相对 v3

| # | 改动 | 说明 |
|---|---|---|
| 1 | **软停充 trickle 模式**（默认） | 保持 status=Charging，天然免疫 Doze |
| 2 | 移除坏节点 `main/current_max` | 实测是实时读数节点，读回值在 0/1550000/2750000 乱跳，写了无效只制造噪音 |
| 3 | 默认区间改 **60/45** | 平均 SOC 约 52%，长期插电最优 |
| 4 | 失控兜底 | 电量超 `CHARGE_STOP+5` 强制切涓流并记日志 |
| 5 | 保留 suspend 模式 | 想硬停充可切 `STOP_MODE=suspend`，配 `ANTI_DOZE=1` |

### v4.1 相对 v4

| # | 改动 | 说明 |
|---|---|---|
| 1 | **修复 service.sh 自杀 bug** | 详见下文 |
| 2 | `TRICKLE_UA` 150000 → **60000** | 详见下文 |

#### 修复：service.sh 自杀 bug（返回 137 / Killed）

v4 的 `service.sh` 里有这样一段：

```bash
# 危险代码（v4.1 已删除）
for p in $(ps -ef | grep slowcharge | grep -v grep | tr -s ' ' | cut -d' ' -f2); do
  [ "$p" != "$$" ] && kill -9 "$p"
done
```

当你手动执行这条命令时：

```bash
su -c "sed -i '...' /data/adb/modules/slowcharge/option.txt && sh .../service.sh"
#                              ↑ 命令行里含 "slowcharge"
```

`ps -ef | grep slowcharge` 会匹配到**调用它的那个 su shell**（PID 不同，
没被 `$$` 排除），然后把它 kill -9 → 终端显示 `Killed`，退出码 **137**
（128+9 = SIGKILL）。

后果：`service.sh` 后续逻辑不确定、pidfile 没写成、**守护没启动**。

v4.1 删掉了这段清理逻辑，只保留 pidfile（本身足以保证守护单例）。

#### 调整：TRICKLE_UA 150000 → 60000

这是修正了一笔算错的账：

```
净充速率 = TRICKLE_UA − 待机耗电(约 50mA)

150mA → 净充 100mA → 每小时涨约 2.2%
```

K40 电池 4520mAh，**1% ≈ 45.2mAh**。若在 94% 时进入涓流，距 100% 只剩 6%
（约 271mAh）：

```
271mAh ÷ 100mA = 2.7 小时就充满
```

一夜必然是 100%，和 v3 的失败表现一样。

改成 **60000（60mA）**：

```
60mA − 50mA = 净充 10mA → 每小时约 0.22%
一夜 8 小时只涨约 1.8%
```

> ⚠️ **重要认知**：软停充是"让电量维持"，不是"让电量下降"。
> 想真正把电量从 92% 拉到 45–60%，**只有物理断电能做到**。
> 若希望涓流期间净放电，可把 `TRICKLE_UA` 调到 40000 左右（见配置说明）。

---

## 五、配置文件详解

配置文件路径：`/data/adb/modules/slowcharge/option.txt`

### 1. 出厂电流上限（安全边界）

```ini
FACTORY_MAX=4920000
```

实测出厂值 = 4.92A。**模块绝不会写入超过此值**，这是硬安全边界。

### 2. 正常充电电流（主要降温手段）

```ini
CURRENT_UA=3000000
```

可在 0 ~ FACTORY_MAX 之间自由调整：

| 值 | 电流 | 说明 |
|---|---|---|
| `3000000` | 3.0A | 出厂的 61%，实测 **31–33℃** ← 默认 |
| `2000000` | 2.0A | 出厂的 41%，实测 27–31℃ |
| `1500000` | 1.5A | 出厂的 31% |
| `1000000` | 1.0A | 出厂的 20%，约 4W，极凉 |

### 3. 软停充时的涓流电流（关键参数）

```ini
TRICKLE_UA=60000
```

净充速率 = `TRICKLE_UA` − 待机耗电（约 50mA）。1% ≈ 45.2mAh。

| 值 | 净充 | 8 小时涨幅 | 说明 |
|---|---|---|---|
| `150000` | 100mA | **+17.7%** | ❌ 会一路充满 |
| `100000` | 50mA | +8.8% | 偏高 |
| **`60000`** | **10mA** | **+1.8%** | ✅ 默认，基本维持 |
| `40000` | −10mA | **−1.8%** | 净放电，电量缓慢下降 |

**选 40000 的好处**：电量不仅不涨，还会缓慢下降，最终自动进入
45–60% 循环。代价是 status 可能变 Discharging（见下方注意事项）。

> ⚠️ 若 `TRICKLE_UA` 低于待机耗电，status 会显示 Discharging，
> 理论上仍有触发 Doze 的可能。v4.1 的软停充设计初衷是避免这一点，
> 所以默认取 60000（略高于待机耗电）。选 40000 需自行权衡。

### 4. 停充模式

```ini
STOP_MODE=trickle
```

| 值 | 说明 |
|---|---|
| **`trickle`** | 软停充，**默认推荐**。保持 status=Charging，免疫 Doze，不需要 wakelock |
| `suspend` | 硬停充（v3 方式）。用 `input_suspend` 真断开充电路径，status 变 Discharging，会触发 Doze，**必须配 `ANTI_DOZE=1`** |

### 5. 按电量停充

```ini
CHARGE_STOP=60
RESUME_AT=45
```

填 `0` = 关闭此功能。

```
电量 >= 60% → 切涓流（TRICKLE_UA）
电量 <= 45% → 恢复 3A 快充
45% ~ 60%   → 保持原状态（迟滞，避免频繁切换）
```

### 6. 硬停充模式下的 Doze 防护

```ini
ANTI_DOZE=0
```

仅当 `STOP_MODE=suspend` 时有意义；`trickle` 模式无需开启。

| 值 | 说明 |
|---|---|
| `0` | 关闭 |
| `1` | wakelock（停充期间持锁，阻止休眠） |
| `2` | wakelock + `dumpsys deviceidle disable`（更彻底，代价更大） |

### 7. USB 输入端最大电流

```ini
USB_UA=1500000
```

填 `0` = 不限制输入端。

本机真实协商值在 `usb/pd_current_max`（约 1550000）。当前 3A 方案下
输入端与电池端几乎同时到顶，是共同瓶颈。此项保持**只降不升**策略
（不会抬高输入上限）。

### 8. 守护循环

```ini
DAEMON=1
INTERVAL=30
DELAY=20
```

| 参数 | 说明 |
|---|---|
| `DAEMON` | 1=开启（每 INTERVAL 秒检查）；0=只在开机写一次，停充功能不可用 |
| `INTERVAL` | 检查间隔（秒），不宜小于 15 |
| `DELAY` | 开机后延迟多少秒再写入（等充电驱动就绪） |

---

## 六、文件结构

安装后位于 `/data/adb/modules/slowcharge/`：

| 文件 | 作用 |
|---|---|
| `module.prop` | 模块信息（id=slowcharge, version=4.1） |
| `option.txt` | **配置文件**，改完执行 service.sh 生效 |
| `common.sh` | 共用逻辑：读配置、节点列表、写入、停充状态机 |
| `service.sh` | 主入口：守护单例、初始化、启动循环 |
| `boot-completed.sh` | 开机完成后再写一次（小米充电守护在此之后启动） |
| `log.txt` | 运行日志，超过 300 行自动截断保留末尾 80 行 |
| `original.txt` | 首次运行时记录的原始节点值 |
| `daemon.pid` | 守护进程 PID |
| `stop_state` | 停充状态（0/1），实现迟滞 |

辅助脚本（同目录，按需手动执行）：

| 文件 | 作用 |
|---|---|
| `probe.sh` | 扫描充电相关节点，列出可写性和当前值 |
| `test_charge.sh` | 连续采样：电量/温度/电流/电压/上限值，验证限流效果 |
| `stop_diag.sh` | 停充功能诊断 |
| `probe_voltage_max.sh` | 探测 `voltage_max` 节点（已证实无效，保留作记录） |
| `verify_vmax.sh` | `voltage_max` 行为验证（已证实无效） |

---

## 七、实测数据

### 限流效果（四轮测试）

| 指标 | 原厂 | v4.1（3A 限流） |
|---|---|---|
| 输入 | USB_PD 11V PPS | USB_PD 8.8V PPS |
| 功率 | 33W | **12.4W** |
| 温度 | 38–42℃ | **31–33℃** |
| 电流 | 4.92A | 2.9–3.0A |

### 限流节点可靠性

`constant_charge_current_max` 在**四轮测试中从未被小米守护进程覆盖**，
10 次采样 `max=` 列全是 3000000，零覆盖。

这是本方案最可靠的节点，也是软停充选择复用它的原因。

### 电池状态（来自 `acc -i`）

```
BATTERY_TYPE=K11A_FMT_4520mah
CHARGE_FULL=4563000        ← 当前实际容量
CHARGE_FULL_DESIGN=4520000 ← 设计容量
CYCLE_COUNT=12             ← 仅 12 次循环
VOLTAGE_MAX_DESIGN=4360000 ← 4.36V 高压电池
```

健康度 = 4563000 / 4520000 = **100.9%**，电池状态非常好。

---

## 八、节点探测结论

对 K40 各充电控制节点的实测结论（非常重要，避免重复踩坑）：

| 节点 | 结论 | 说明 |
|---|---|---|
| `battery/constant_charge_current_max` | ✅ **可用** | 出厂 4920000，**四轮零覆盖**，本方案核心节点 |
| `battery/input_suspend` | ✅ 可用 | 真开关，但停充后 status=Discharging → **触发 Doze** |
| `battery/battery_charging_enabled` | ❌ **假开关** | 写 0 后 status 纹丝不动，电流照充。**BCL 默认用它，故 BCL 在 K40 上必然失效** |
| `battery/voltage_max` | ❌ 无效 | 能写入、能保持，但 **status 始终 Charging**，充电 IC 不执行 |
| `main/current_max` | ❌ 坏节点 | 实时读数节点，读回值在 0/1550000/2750000 乱跳。**v4 已移除** |
| `main/constant_charge_current_max` | ⚠️ 被钳位 | 写 60000 读回 50000（系统钳位），无害但刷屏 |

### voltage_max 的详细排除过程

两轮实测：

| 测试 | 写入保持 | status 变化 | 电流 |
|---|---|---|---|
| 4.05V | ✅ 全程 | ❌ 10/10 都是 Charging | 39–205mA |
| 3.90V | ✅ 全程 | ❌ 10/10 都是 Charging | 41–208mA |

对比 `input_suspend=1` 能让 status **立刻**变 Discharging——真开关和假开关
一眼可分。`voltage_max` 写 3.9V（比当前 4.37V 低 0.47V）status 纹丝不动。

深层原因：K40 是 pm8150b + bq2597x 电荷泵架构，**截止电压由充电 IC 硬件
寄存器决定**，Android 的 `voltage_max` 只是 power_supply 框架的属性字段，
高通驱动常只在初始化时读一次，运行时不响应动态写入。

> 补充：即便可用也不是好方案。你这颗是 **4.36V 高压电池**
> （`VOLTAGE_MAX_DESIGN=4360000`），通用换算表"4.05V ≈ 80%"完全不适用。
> 而 `capacity` 是电量计直接算出的，不受化学体系和温度影响，精度高得多。

### ACC 扫描交叉验证

后来用 `acc -t` 扫描 32 个候选开关，只有 2 个可用：

| # | 开关 | 结果 |
|---|---|---|
| **9** | `battery/constant_charge_current_max` | ✅ 电流型开关（可降电流，status 不变） |
| **10** | `battery/input_suspend` | ✅ 可用（但触发 Doze） |

**ACC 的独立扫描完全印证了手动探测的结论**，包括 `voltage_max` 和
`battery_charging_enabled` 都是死路。

---

## 九、单位换算

⚠️ **最容易踩的坑**，差 1000 倍：

| 系统 | 单位 | 3A 怎么写 |
|---|---|---|
| **v4.1 / sysfs 节点** | **微安 μA** | `3000000` |
| **ACC 的 `mcc`** | **毫安 mA** | `3000` |
| **ACC 的 chargingSwitch** | **微安 μA**（跟随 sysfs） | `3000000` |

换算：

```
1A = 1000 mA = 1000000 μA
微安 → 毫安：除以 1000
```

常见值对照：

| 配置值（μA） | 实际电流 |
|---|---|
| `4920000` | 4.92A（出厂上限） |
| `3000000` | 3.0A |
| `2000000` | 2.0A |
| `1000000` | 1.0A |
| `250000` | 250mA |
| `60000` | 60mA |
| `40000` | 40mA |

---

## 十、验证方法

### 1. 确认守护在跑

```bash
su -c "ps -ef | grep slowcharge | grep -v grep"
```

应看到**一行** `busybox sh /data/adb/modules/slowcharge/service.sh`。

> 空输出 = 守护没起来（可能是自杀 bug 或启动失败）。

### 2. 确认限流生效

```bash
su -c "cat /sys/class/power_supply/battery/constant_charge_current_max"
```

- 正常充电状态：`3000000`
- 软停充状态：`60000`（或你设的其他值）
- `4920000` = 模块没生效

### 3. 完整采样（推荐）

```bash
su -c "sh /sdcard/test_charge.sh 2>&1 | tee /sdcard/charge_result.txt"
```

10 次采样 × 20 秒。重点看两列：**`max=` 是否全程 3000000**、温度是否 ≤ 35℃。

> 注意：电量高时系统自身会限流，实际电流可能只有 2.0–2.5A。
> **判断标准唯一：看 `max=` 列**，实际电流多少由系统策略决定。
> 想看 3A 跑满，需等电量降到 50% 以下（原厂在此是恒流区）。

### 4. 验证软停充（关键）

临时把阈值调到当前电量以下（假设当前 87%）：

```bash
su -c "sed -i 's/^CHARGE_STOP=.*/CHARGE_STOP=75/;s/^RESUME_AT=.*/RESUME_AT=70/' \
  /data/adb/modules/slowcharge/option.txt && \
  /data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/service.sh"
```

两分钟后：

```bash
su -c "cat /sys/class/power_supply/battery/constant_charge_current_max; \
       cat /sys/class/power_supply/battery/status"
```

**成功标志**：`60000` + `Charging`

> status 必须是 **Charging 而不是 Discharging**——这正是 v4 软停充与
> v3 硬停充的本质区别，也是它免疫 Doze 的原因。

测完改回：

```bash
su -c "sed -i 's/^CHARGE_STOP=.*/CHARGE_STOP=60/;s/^RESUME_AT=.*/RESUME_AT=45/' \
  /data/adb/modules/slowcharge/option.txt && \
  /data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/service.sh"
```

### 5. 过夜验证（最终检验）

```bash
su -c "cat /sys/class/power_supply/battery/capacity; \
       cat /sys/class/power_supply/battery/constant_charge_current_max; \
       tail -20 /data/adb/modules/slowcharge/log.txt"
```

三个看点：

1. 电量没涨到 100%
2. `constant_charge_current_max` 是涓流值
3. **日志时间戳连续**——不再出现十几小时空白（Doze 被绕开的铁证）

第 3 点最重要。

---

## 十一、故障排查

### 症状：终端显示 `Killed` / 退出码 137

**原因**：v4 及更早版本的自杀 bug（见"v4.1 改进"）。手动执行 service.sh 时，
命令行含 "slowcharge"，被 `ps | grep slowcharge` 清理逻辑误杀。

**解决**：升级到 v4.1。若暂时无法升级，改用不含该字符串的方式调用，
或直接重启让开机流程自动拉起。

### 症状：守护进程不存在

**排查**：

```bash
su -c "cat /data/adb/modules/slowcharge/daemon.pid; \
       tail -20 /data/adb/modules/slowcharge/log.txt"
```

- 日志停在"已终止旧守护" = 自杀 bug，升 v4.1
- 日志有 `!! 未找到任何可写电池端节点` = 节点路径不对
- 日志空白 = service.sh 根本没跑

### 症状：限流没生效，节点还是 4920000

1. 确认模块在 APatch 里**开关是打开的**（曾出现过手动装完又禁用）
2. 确认守护在跑（见上文）
3. 看日志是否有 `FAIL`/`WARN`
4. 执行 `boot-completed.sh` 补写：

```bash
su -c "/data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/boot-completed.sh"
```

### 症状：日志刷屏 `main/constant_charge_current_max 写入 60000 读回 50000`

无害。系统把该节点最小值钳在 50000，比目标更保守。
主节点 `battery/constant_charge_current_max` 才是真正起作用的那个。

### 症状：日志每 30 秒刷一条 WARN，冲掉有用记录

日志 300 行自动截断，有用的记录会被冲掉。可去掉该节点：

```bash
su -c "sed -i '/main\/constant_charge_current_max/d' \
  /data/adb/modules/slowcharge/common.sh && \
  /data/adb/ap/bin/busybox sh /data/adb/modules/slowcharge/service.sh"
```

### 症状：睡醒电量 100%

按顺序排查：

1. **先看日志时间戳是否连续**——十几小时空白 = Doze 冻结
2. 确认 `STOP_MODE=trickle`（不是 suspend）
3. 确认 `TRICKLE_UA` 不是 150000（会净充 100mA/小时）
4. 确认 `CHARGE_STOP` 没被设成 0

### 症状：卡开机 / 无法启动

模块本身不挂载任何系统文件，**不会导致卡开机**。
若遇到，长按电源键进 fastboot，或用 APatch 的模块禁用机制。

---

## 十二、已知限制

### 1. 软件方案的固有边界

v4.1 解决了最主要的 Doze 风险，但残余风险仍存在：

| 风险 | 可能性 | 后果 |
|---|---|---|
| 守护进程被杀（内存不足、清理工具、OTA） | 低 | 停充失效，可能充到 100% |
| APatch 模块被意外禁用 | 低 | 全部失效 |
| 系统更新后节点路径变化 | 中 | 限流失效（日志显示 FAIL） |
| 充电 IC 固件层行为 | 低 | 不受 sysfs 控制 |

这些是**用户态进程的固有局限**，Android 上任何软件方案都绕不开。

### 2. 软停充不能降低电量

涓流是"维持"，不是"放电"。想把电量从 92% 拉到 45–60%，
**只有物理断电能做到**（拔充电器或智能插座）。

### 3. 需要物理断电才最可靠

对长期插电的备用机，推荐叠加**智能定时插座**：
不依赖 root、不依赖守护进程、不存在充到 100% 的可能。

两层职责应分开：

| 层 | 职责 | 失效后果 |
|---|---|---|
| v4.1（软件） | 通电时限流降温 | 失效 → 充到 100%（缓慢老化，可接受） |
| 插座（硬件） | 何时通电 | 失效 → 只剩 v4.1 软停充，仍不会过充 |

### 4. 与 ACC 不能同时开

两者都写 `constant_charge_current_max`，会互相抢。
选一个即可。

---

## 十三、版本历史

### v4.1（2025-10-09）

- **修复** `service.sh` 自杀 bug（返回 137）
- **调整** `TRICKLE_UA` 150000 → 60000

### v4.0

- **新增** 软停充 trickle 模式（默认），绕开 Doze
- **移除** 坏节点 `main/current_max`
- **调整** 默认区间 80/70 → 60/45
- **新增** 失控兜底（电量超 CHARGE_STOP+5 强制切涓流）

### v3

- 硬停充（input_suspend）
- **已知缺陷**：停充后 status=Discharging → Doze 冻结守护 → 充到 100%

### v2 / v1

- 早期版本，仅做基础限流

---

## 附录：相关项目评估

在寻找替代方案过程中评估过的项目，结论供参考：

| 项目 | 结论 |
|---|---|
| **BCL (BatteryChargeLimiter)** | ❌ 默认开关 `battery_charging_enabled` 在 K40 是假开关；且不支持限流 |
| **AccA** | ❌ 停更多年，会覆盖 ACC 版本，官方劝退 |
| **ACC v2023.10.16** | ✅ 可用（需元模块 Hybrid Mount + Magic Mount + tmpfs） |
| **ACC v2025.5.18-dev** | 含 APatch 补丁，但安装时曾卡开机 |
| **mountify** | ⚠️ APatch 11170+ 自动元模块，但与 ACC 组合曾卡开机 |
| **Hybrid Mount** | ✅ 推荐，可给 ACC 单独指定后端，冲突会明确报错 |
| **ChargeLimes** | ✅ 免 root，通过 HTTP 控制智能插座，适合有 HTTP 插座的场景 |

### 关于 ACC 的关键信息

ACC 的路径分两层：

| 路径 | 作用 | 性质 |
|---|---|---|
| `/data/adb/vr25/acc/` | 真实文件存放处 | 持久化 |
| `/dev/.vr25/acc/` | 运行时符号链接 | **易失**（/dev 是 tmpfs，重启清空） |

所以 `acc: not found` 通常意味着**链接没建立**（初始化没跑），
而非文件丢失。手动补一次：

```bash
su -c "/data/adb/vr25/acc/service.sh"
```

### K40 上 ACC 的推荐配置

对应 v4.1 的 3A 限流 + 60/45 停充：

```bash
acc -s s="battery/constant_charge_current_max 3000000 60000 --"
acc -s pc=60 rc=45
```

配置落在 `/data/adb/vr25/acc-data/config.txt`：

```bash
chargingSwitch=(battery/constant_charge_current_max 3000000 60000 --)
capacity=(10 101 45 60 false false)
```

> `cooldown_capacity=101` 是故意设成不可达来禁用该功能。
> `shutdown_capacity=10` 表示放电到 10% 才关机保护。

---

*文档最后更新：2025-10-10*
