#!/system/bin/sh
# APatch / Magisk / KernelSU 通用
# v4：软停充绕开 Doze + 守护单例 + 残留清理

MODDIR=${0%/*}
. "$MODDIR/common.sh"

PIDFILE="$MODDIR/daemon.pid"

log "===== 启动 (pid $$) 模式=$STOP_MODE 正常=${CURRENT_UA}uA 涓流=${TRICKLE_UA}uA 停充=${CHARGE_STOP}% ====="

# 退出时释放 wakelock
trap 'release_lock; exit 0' INT TERM

# ---- 杀掉上一轮守护 ----
if [ -f "$PIDFILE" ]; then
  OLD=$(cat "$PIDFILE" 2>/dev/null)
  OLD=$(num "$OLD" 0)
  if [ "$OLD" -gt 0 ] && [ "$OLD" != "$$" ]; then
    kill -9 "$OLD" 2>/dev/null && log "已终止旧守护 (pid $OLD)"
  fi
  rm -f "$PIDFILE"
fi

# 注意：不要用 ps | grep slowcharge 清理进程
# 手动执行 "sh /data/adb/modules/slowcharge/service.sh" 时，
# 命令行本身含 "slowcharge"，会匹配到调用它的父 shell 并误杀（返回 137/Killed）。
# pidfile 机制已足够保证守护单例，无需额外清理。

# ---- 首次运行记录原始值 ----
if [ ! -f "$MODDIR/original.txt" ]; then
  {
    echo "# 安装时记录的原始值（如需完全还原，手动写回即可）"
    for p in $BAT_PATHS $USB_PATHS; do
      [ -f "$p" ] && echo "$p = $(cat "$p" 2>/dev/null)"
    done
    echo "/sys/class/power_supply/battery/voltage_max = $(cat /sys/class/power_supply/battery/voltage_max 2>/dev/null)"
  } > "$MODDIR/original.txt"
  log "已记录原始值到 original.txt"
fi

# ---- 初始化硬停充开关（仅 suspend 模式）----
[ "$STOP_MODE" = "suspend" ] && init_stop_switch

sleep "$DELAY"
apply

if [ "$DAEMON" = "1" ]; then
  (
    while true; do
      sleep "$INTERVAL"
      plugged && apply
    done
  ) &
  DPID=$!
  echo "$DPID" > "$PIDFILE"
  log "守护启动 (pid $DPID)，间隔 ${INTERVAL}s"
else
  log "守护关闭（DAEMON=0）"
fi

log "service.sh 结束"
