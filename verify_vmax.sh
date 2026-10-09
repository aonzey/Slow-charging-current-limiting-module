#!/system/bin/sh
# ============================================================
#  verify_vmax.sh —— voltage_max 行为验证
#
#  背景：probe_voltage_max.sh 已确认 battery/voltage_max 能写入并保持，
#        但「节点能写」≠「充电芯片会执行」。本脚本做行为验证：
#        写入目标电压后连续采样，看充电是否真的停下。
#
#  用法：插着充电器，root 终端执行
#        sh /sdcard/verify_vmax.sh 4050000 2>&1 | tee /sdcard/vmax_verify.txt
#        参数 = 目标电压(μV)，默认 4050000
#        可选第二参数 = 采样次数，默认 10（每次 30 秒，共 5 分钟）
#
#  安全：结束或中断时会自动还原原始电压值
# ============================================================

TARGET=${1:-4050000}
TIMES=${2:-10}
VMAX=/sys/class/power_supply/battery/voltage_max
OUT=/sdcard/vmax_verify.txt

say() { echo "$@"; }

# ---- 参数校验 ----
case "$TARGET" in ''|*[!0-9]*) say "!! 目标电压必须是数字(μV)"; exit 1 ;; esac
case "$TIMES"   in ''|*[!0-9]*) TIMES=10 ;; esac
[ "$TARGET" -lt 3500000 ] && { say "!! 电压过低(<3.5V)，拒绝执行"; exit 1; }
[ "$TARGET" -gt 4500000 ] && { say "!! 电压过高(>4.5V)，拒绝执行"; exit 1; }

# ---- 捕获中断，确保还原 ----
ORIG=""
cleanup() {
  [ -n "$ORIG" ] && { echo "$ORIG" > "$VMAX" 2>/dev/null; say ""; say "[还原] voltage_max 已写回 $ORIG"; }
  exit 0
}
trap cleanup INT TERM

[ -f "$VMAX" ] || { say "!! 节点不存在: $VMAX"; exit 1; }

ORIG=$(cat "$VMAX" 2>/dev/null)
say "===== 0. 初始状态 ====="
say "voltage_max 原始值 = $ORIG μV ($((ORIG / 1000000)).$((ORIG % 1000000 / 100000))V)"
say "目标电压           = $TARGET μV ($((TARGET / 1000000)).$((TARGET % 1000000 / 100000))V)"
say "电量               = $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)%"
say "状态               = $(cat /sys/class/power_supply/battery/status 2>/dev/null)"
say "voltage_now        = $(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null) μV"
say ""

VN=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
if [ -n "$VN" ] && [ "$VN" -gt "$TARGET" ] 2>/dev/null; then
  say ">> 当前电压($VN) 已高于目标($TARGET)，充电应当立刻停止 —— 这是最干净的验证场景"
else
  say ">> 当前电压($VN) 低于目标($TARGET)，需充电到目标电压才见效，观察电量是否停止上涨"
fi
say ""

# ---- 写入 ----
say "===== 1. 写入目标电压 ====="
chmod 0644 "$VMAX" 2>/dev/null
if echo "$TARGET" > "$VMAX" 2>/dev/null; then
  sleep 1
  NOW=$(cat "$VMAX" 2>/dev/null)
  say "写入后读回 = $NOW"
  [ "$NOW" != "$TARGET" ] && say "!! 写入未保持，驱动可能不支持"
else
  say "!! 写入失败"; cleanup
fi
say ""

say "===== 2. 开始采样（${TIMES} 次 × 30 秒）====="
say "格式: 电量% | 状态 | 电压μV | 电流mA | voltage_max"
say "--------------------------------------------------------------"

STOPPED=0
i=1
while [ "$i" -le "$TIMES" ]; do
  CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  ST=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
  V=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
  C=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  M=$(cat "$VMAX" 2>/dev/null)

  # 电流换算成 mA：|-3028318| / 1000
  ABS=${C#-}
  MA=$((ABS / 1000))

  say "[$i/$TIMES] ${CAP}% | ${ST} | ${V} | ${MA}mA | max=${M}"

  # 判定：非充电状态 且 电流很小（<150mA）
  case "$ST" in
    *Charging*) ;;
    *)
      if [ "$MA" -lt 150 ] 2>/dev/null; then STOPPED=$((STOPPED + 1)); fi
      ;;
  esac

  i=$(( i + 1 ))
  [ "$i" -le "$TIMES" ] && sleep 30
done

say "--------------------------------------------------------------"
say ""

say "===== 3. 结论 ====="
say "采样中出现「非充电状态且电流<150mA」的次数: $STOPPED / $TIMES"
say ""
if [ "$STOPPED" -ge 3 ]; then
  say "✅ 【可用】充电确实停下了 —— 驱动/充电IC会执行 voltage_max"
  say "   建议：用 voltage_max 做硬件级天花板，替代不可靠的 input_suspend"
elif [ "$STOPPED" -ge 1 ]; then
  say "⚠️  【部分生效】偶尔停下，可能受系统温控/充电守护进程干扰"
  say "   建议：再跑一轮确认，或配合守护循环定期重写"
else
  say "❌ 【无效】充电从未停止 —— 驱动只是存了值，充电IC不看它"
  say "   建议：放弃 voltage_max，改用 v4 加固方案（wakelock + input_suspend）"
fi
say ""

say "===== 4. 电压 <-> 电量 校准参考 ====="
say "当前实测：voltage_now=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null) μV 对应 $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)%"
say "（多测几个点可画出你这台机器的电压-电量曲线，用于精确设定目标）"
say ""

# ---- 还原 ----
say "===== 5. 还原 ====="
echo "$ORIG" > "$VMAX" 2>/dev/null
sleep 1
say "voltage_max 已还原为: $(cat $VMAX 2>/dev/null)"
say "当前状态: $(cat /sys/class/power_supply/battery/status 2>/dev/null)"
say ""
say "结果已保存到 $OUT"
say "把这个文件内容发出来即可。"
ORIG=""
