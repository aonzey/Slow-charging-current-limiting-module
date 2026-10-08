#!/system/bin/sh
# ============================================================
#  charge_test.sh —— 插原装 33W 头时的限流效果验证
#  用法：插好充电器后，root 终端执行
#        sh /sdcard/charge_test.sh 2>&1 | tee /sdcard/charge_result.txt
#  脚本会连续采样 10 次（每次间隔 20 秒，共约 3.5 分钟）
# ============================================================

say() { echo "$@"; }

say "===== 0. 环境 ====="
say "设备: $(getprop ro.product.device)  系统: $(getprop ro.build.version.release)"
say "SELinux: $(getenforce 2>/dev/null)"
say ""

say "===== 1. 模块是否在运行 ====="
if [ -f /data/adb/modules/slowcharge/log.txt ]; then
  say "--- 模块日志最后 12 行 ---"
  tail -12 /data/adb/modules/slowcharge/log.txt
else
  say "!! 未找到模块日志，模块可能没安装或没启动"
fi
say ""

say "===== 2. 握手情况（关键：确认真的在快充）====="
say "usb/type       = $(cat /sys/class/power_supply/usb/type 2>/dev/null)"
say "  (USB_DCP / USB_PD = 充电头；USB = 电脑口，没插充电头)"
say "usb/voltage_now= $(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null)"
say "  (5000000=5V  9000000=9V  11000000=11V)"
say "usb/current_max= $(cat /sys/class/power_supply/usb/current_max 2>/dev/null)"
say ""

say "===== 3. 限流节点状态 ====="
say "constant_charge_current_max = $(cat /sys/class/power_supply/battery/constant_charge_current_max 2>/dev/null)"
say "  (目标 2000000；若显示 4920000 说明模块没生效或被覆盖)"
say ""

say "===== 4. 开始连续采样（10 次 × 20 秒）====="
say "格式: 电量% | 温度℃ | 电流A | 电压V | 上限值 | 状态"
say "--------------------------------------------------------------"

i=1
while [ "$i" -le 10 ]; do
  CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  TEMP=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  CUR=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  VOL=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
  MAX=$(cat /sys/class/power_supply/battery/constant_charge_current_max 2>/dev/null)
  ST=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
  CT=$(cat /sys/class/power_supply/battery/charge_type 2>/dev/null)

  # 电流取绝对值并换算成 A：|-370605| / 1000000 = 0.37
  ABS=${CUR#-}
  A=$(( ABS / 100000 ))
  A_INT=$(( A / 10 ))
  A_DEC=$(( A % 10 ))

  # 温度 /10
  T=$(( TEMP / 10 ))

  say "[$i/10] ${CAP}% | ${T}℃ | ${A_INT}.${A_DEC}A | ${VOL} | max=${MAX} | ${ST} | ${CT}"

  i=$(( i + 1 ))
  [ "$i" -le 10 ] && sleep 20
done

say "--------------------------------------------------------------"
say ""
say "===== 5. 采样结束后的最终状态 ====="
say "constant_charge_current_max = $(cat /sys/class/power_supply/battery/constant_charge_current_max 2>/dev/null)"
say "  若此项在整轮采样中一直是 2000000 -> 模块完全顶住了厂商覆盖"
say "  若此项在 2000000 和 4920000 之间来回跳 -> 守护循环在工作（正常，看平均电流）"
say ""
say "===== 完成 ====="
say "结果已保存到 /sdcard/charge_result.txt"
say "把这个文件内容发出来即可。"
