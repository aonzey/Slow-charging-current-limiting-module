#!/system/bin/sh
# ============================================================
#  probe.sh —— 红米K40 充电节点探测（只读 + 安全试写）
#  用法：先插上充电器，然后 root 终端执行
#        sh /sdcard/probe.sh 2>&1 | tee /sdcard/probe_result.txt
#  结果会同时打印到屏幕并保存到 /sdcard/probe_result.txt
# ============================================================

OUT=/sdcard/probe_result.txt

say() { echo "$@"; }

say "===== 0. 环境 ====="
say "设备: $(getprop ro.product.device 2>/dev/null)  机型: $(getprop ro.product.model 2>/dev/null)"
say "系统: $(getprop ro.build.version.release 2>/dev/null)  API: $(getprop ro.build.version.sdk 2>/dev/null)"
say "SELinux: $(getenforce 2>/dev/null)"
say "当前充电状态: $(cat /sys/class/power_supply/battery/status 2>/dev/null)"
say "当前电量: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)%"
say "电池温度: $(cat /sys/class/power_supply/battery/temp 2>/dev/null) (需除以10得℃)"

say ""
say "===== 1. power_supply 目录下所有设备 ====="
ls /sys/class/power_supply/ 2>/dev/null

say ""
say "===== 2. 关键状态节点当前值 ====="
for p in \
  /sys/class/power_supply/battery/status \
  /sys/class/power_supply/battery/capacity \
  /sys/class/power_supply/battery/temp \
  /sys/class/power_supply/battery/voltage_now \
  /sys/class/power_supply/battery/current_now \
  /sys/class/power_supply/battery/charge_type \
  /sys/class/power_supply/usb/voltage_now \
  /sys/class/power_supply/usb/current_now \
  /sys/class/power_supply/usb/type \
  ; do
  [ -f "$p" ] && say "$p = $(cat "$p" 2>/dev/null)"
done

say ""
say "===== 3. 全量扫描：所有含 current/charge/voltage/suspend 的节点 ====="
find /sys/class/power_supply -maxdepth 2 \( \
  -name '*current*' -o -name '*charge*' -o -name '*voltage*' \
  -o -name '*suspend*' -o -name '*input*' \) -type f 2>/dev/null | sort | while read f; do
  v=$(cat "$f" 2>/dev/null)
  w="r--"
  [ -w "$f" ] && w="rw-"
  say "$w $f = $v"
done

say ""
say "===== 4. 试写测试（自动判断单位，只往"变小"的方向写，不会调高功率）====="
say ""

# 候选限流节点：电池端 + 输入端
CANDIDATES="
/sys/class/power_supply/battery/constant_charge_current_max
/sys/class/power_supply/battery/current_max
/sys/class/power_supply/battery/fcc_max
/sys/class/power_supply/main-charger/current_max
/sys/class/power_supply/main-charger/constant_charge_current_max
/sys/class/power_supply/parallel/constant_charge_current_max
/sys/class/power_supply/bms/constant_charge_current_max
/sys/class/power_supply/qcom-battery/constant_charge_current_max
/sys/class/power_supply/battery/constant_charge_current
/sys/class/power_supply/battery/fcc
/sys/class/power_supply/usb/current_max
/sys/class/power_supply/usb/input_current_limit
/sys/class/power_supply/usb/pd_current_max
/sys/class/power_supply/typec/current_max
"

for p in $CANDIDATES; do
  [ -f "$p" ] || continue

  ORIG=$(cat "$p" 2>/dev/null)
  case "$ORIG" in ''|*[!0-9-]*) say "[$p] 读取失败或非数字($ORIG)，跳过"; continue ;; esac

  # 判断单位：原值 > 100000 视为 μA，否则视为 mA
  if [ "$ORIG" -gt 100000 ] 2>/dev/null; then
    UNIT="uA"; TARGET=2000000   # 2A
  else
    UNIT="mA"; TARGET=2000      # 2A
  fi

  # 只往小的方向写（安全），原值已经比目标小就不动
  if [ "$ORIG" -le "$TARGET" ] 2>/dev/null; then
    say "[$p] 原值 $ORIG $UNIT 已 <= ${TARGET}${UNIT}，跳过写入"
    continue
  fi

  chmod 0644 "$p" 2>/dev/null

  if echo "$TARGET" > "$p" 2>/dev/null; then
    sleep 2
    NOW=$(cat "$p" 2>/dev/null)
    if [ "$NOW" = "$TARGET" ]; then
      say "[可写✅] $p"
      say "         原值 $ORIG $UNIT  ->  写入 $TARGET $UNIT  ->  2秒后读回 $NOW  【保持住了】"
    else
      say "[可写但被改回⚠️] $p"
      say "         原值 $ORIG $UNIT  ->  写入 $TARGET $UNIT  ->  2秒后读回 $NOW  【被守护进程覆盖】"
    fi
  else
    say "[写失败❌] $p  原值 $ORIG $UNIT （只读 / 内核拒绝 / SELinux）"
  fi
  say ""
done

say "===== 5. 写完后的实际充电电流 ====="
say "current_now = $(cat /sys/class/power_supply/battery/current_now 2>/dev/null) （负值=放电，正值=充电；单位通常为 μA）"
say "status = $(cat /sys/class/power_supply/battery/status 2>/dev/null)"
say "charge_type = $(cat /sys/class/power_supply/battery/charge_type 2>/dev/null)"

say ""
say "===== 6. 充电暂停类节点（用于'充到80%停'）====="
for p in \
  /sys/class/power_supply/battery/battery_charging_enabled \
  /sys/class/power_supply/battery/input_suspend \
  /sys/class/power_supply/battery/charging_enabled \
  /sys/class/power_supply/battery/store_mode \
  /sys/class/power_supply/battery/batt_slate_mode \
  /sys/class/power_supply/battery/charge_disable \
  ; do
  [ -f "$p" ] && say "$p = $(cat "$p" 2>/dev/null)"
done

say ""
say "===== 完成 ====="
say "结果已保存到 $OUT"
say "把这个文件的内容发出来即可。"
