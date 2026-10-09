#!/system/bin/sh
# ============================================================
#  probe_voltage_max.sh —— 探测 K40 是否支持「充电截止电压上限」
#
#  背景：input_suspend 硬停充依赖用户态守护循环，
#        Android Doze 会把守护冻结数小时，导致停充守不住、充到 100%。
#        voltage_max 是充电管理芯片自己执行的硬件级上限，
#        就算脚本被冻结也照样生效，是长期插电备用机的理想方案。
#
#  用法：插着充电器，root 终端执行
#        sh /sdcard/probe_voltage_max.sh 2>&1 | tee /sdcard/vmax_result.txt
#
#  安全：所有写入都会自动还原，不会把你的配置改坏
# ============================================================

OUT=/sdcard/vmax_result.txt
say() { echo "$@"; }

say "===== 0. 环境 ====="
say "设备: $(getprop ro.product.device)  系统: $(getprop ro.build.version.release)"
say "SELinux: $(getenforce 2>/dev/null)"
say "电量: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)%"
say "状态: $(cat /sys/class/power_supply/battery/status 2>/dev/null)"
say ""

say "===== 1. 电量 <-> 电压 对应基准（后面换算要用）====="
say "voltage_now = $(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null) μV"
say "  (即 $(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null) / 1000000 V)"
say "voltage_ocv = $(cat /sys/class/power_supply/battery/voltage_ocv 2>/dev/null) μV"
say "temp        = $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (除以10=℃)"
say ""

say "===== 2. 扫描所有电压相关节点 ====="
say "--- 带 voltage 关键字 ---"
find /sys/class/power_supply -maxdepth 2 -type f -name '*voltage*' 2>/dev/null | sort | while read f; do
  w="r--"; [ -w "$f" ] && w="rw-"
  say "$w $f = $(cat "$f" 2>/dev/null)"
done
say ""
say "--- 带 max / limit / term 关键字（可能是上限类）---"
find /sys/class/power_supply -maxdepth 2 -type f \( -name '*max*' -o -name '*limit*' -o -name '*term*' \) 2>/dev/null | sort | while read f; do
  w="r--"; [ -w "$f" ] && w="rw-"
  say "$w $f = $(cat "$f" 2>/dev/null)"
done
say ""

say "===== 3. 候选「充电截止电压」节点是否存在 ====="
FOUND=0
for p in \
  /sys/class/power_supply/battery/voltage_max \
  /sys/class/power_supply/battery/constant_charge_voltage_max \
  /sys/class/power_supply/battery/voltage_max_design \
  /sys/class/power_supply/battery/vmax \
  /sys/class/power_supply/battery/charge_voltage_max \
  /sys/class/power_supply/main/voltage_max \
  /sys/class/power_supply/main/constant_charge_voltage_max \
  /sys/class/power_supply/bms/voltage_max \
  /sys/class/power_supply/qcom-battery/voltage_max \
  ; do
  if [ -f "$p" ]; then
    perm=$(ls -l "$p" 2>/dev/null | cut -c1-10)
    say "[存在] $p = $(cat $p 2>/dev/null)   $perm"
    FOUND=1
  fi
done
[ "$FOUND" = "0" ] && say "!! 未找到任何候选节点（内核可能不暴露此接口）"
say ""

say "===== 4. 写入测试：设 4.05V（约对应 80% 电量）====="
say "目标值: 4050000 μV"
say ""

# 逐个候选节点试写
for p in \
  /sys/class/power_supply/battery/voltage_max \
  /sys/class/power_supply/battery/constant_charge_voltage_max \
  /sys/class/power_supply/battery/vmax \
  /sys/class/power_supply/battery/charge_voltage_max \
  /sys/class/power_supply/main/voltage_max \
  /sys/class/power_supply/main/constant_charge_voltage_max \
  /sys/class/power_supply/bms/voltage_max \
  ; do
  [ -f "$p" ] || continue

  ORIG=$(cat "$p" 2>/dev/null)
  case "$ORIG" in ''|*[!0-9]*) say "[$p] 读取失败或非数字($ORIG)，跳过"; continue ;; esac

  say "--- 测试 $p ---"
  say "  原始值: $ORIG μV ($((ORIG / 1000000)).$((ORIG % 1000000 / 100000))V)"

  # 如果原始值是 mV 量级（<100000），单位换算
  if [ "$ORIG" -lt 100000 ] 2>/dev/null; then
    TARGET=4050
    UNIT="mV"
    say "  (原始值 <100000，判定单位为 mV，目标改为 4050mV)"
  else
    TARGET=4050000
    UNIT="μV"
  fi

  chmod 0644 "$p" 2>/dev/null
  if echo "$TARGET" > "$p" 2>/dev/null; then
    sleep 3
    NOW=$(cat "$p" 2>/dev/null)
    if [ "$NOW" = "$TARGET" ]; then
      say "  [可写并保持✅] 读回 $NOW $UNIT"
      say "  ***** 这个节点可用！建议采用 *****"
    else
      say "  [可写但被改回⚠️] 读回 $NOW $UNIT"
    fi
  else
    say "  [写失败❌] 只读 / 内核拒绝 / SELinux"
  fi

  # 还原
  echo "$ORIG" > "$p" 2>/dev/null
  sleep 1
  say "  已还原为: $(cat $p 2>/dev/null)"
  say ""
done

say "===== 5. 关键验证：写入 4.05V 后，充电行为有没有真的停下 ====="
say "这一步很重要 —— 节点能写 ≠ 充电管理芯片会执行"
say ""
say "如需手动验证，可执行："
say "  1) echo 4050000 > <上面标记为可用的节点>"
say "  2) 插着充电器观察 5 分钟"
say "  3) 看 status 是否变成 Not charging、current_now 是否趋近 0"
say "  4) 看电量是否停止上涨"
say ""

say "===== 6. 备选方案探测：充电截止相关的其他开关 ====="
for p in \
  /sys/class/power_supply/battery/charge_term_current \
  /sys/class/power_supply/battery/charge_full_design \
  /sys/class/power_supply/battery/charge_full \
  /sys/class/power_supply/battery/capacity_max \
  /sys/class/power_supply/battery/soh \
  /sys/class/power_supply/battery/cycle_count \
  ; do
  [ -f "$p" ] && say "$p = $(cat $p 2>/dev/null)"
done
say ""

say "===== 7. 补充：当前停充开关状态 ====="
say "input_suspend = $(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null)  (0=充电 1=停充)"
say "battery_charging_enabled = $(cat /sys/class/power_supply/battery/battery_charging_enabled 2>/dev/null)"
say ""

say "===== 8. Doze 相关（判断守护被冻结的原因）====="
say "dumpsys deviceidle 可能较慢，如卡住可按 Ctrl+C 跳过"
say ""

say "===== 完成 ====="
say "结果已保存到 $OUT"
say "把这个文件内容发出来即可。"
