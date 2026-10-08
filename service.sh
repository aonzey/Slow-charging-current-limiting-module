#!/system/bin/sh
# APatch / Magisk / KernelSU 通用
# v3：守护单例 + 停充逻辑与 status 解耦

MODDIR=${0%/*}
. "$MODDIR/common.sh"

PIDFILE="$MODDIR/daemon.pid"

log "===== 启动 (pid $$) 电池端 ${CURRENT_UA}uA / 输入端 ${USB_UA}uA / 停充 ${CHARGE_STOP}% ====="

# ---- 杀掉上一轮遗留的守护 ----
if [ -f "$PIDFILE" ]; then
  OLD=$(cat "$PIDFILE" 2>/dev/null)
  OLD=$(num "$OLD" 0)
  if [ "$OLD" -gt 0 ] && [ "$OLD" != "$$" ]; then
    kill -9 "$OLD" 2>/dev/null && log "已终止旧守护 (pid $OLD)"
  fi
  rm -f "$PIDFILE"
fi

# 兼容性兜底：清掉可能存在的野进程（不含自己）
for p in $(ps -ef | grep slowcharge | grep -v grep | tr -s ' ' | cut -d' ' -f2); do
  [ "$p" != "$$" ] && kill -9 "$p" 2>/dev/null && log "清理残留进程 (pid $p)"
done

# ---- 首次运行记录原始值 ----
if [ ! -f "$MODDIR/original.txt" ]; then
  {
    echo "# 安装时记录的原始值（如需完全还原，手动写回即可）"
    for p in $BAT_PATHS $USB_PATHS; do
      [ -f "$p" ] && echo "$p = $(cat "$p" 2>/dev/null)"
    done
  } > "$MODDIR/original.txt"
  log "已记录原始值到 original.txt"
fi

# ---- 初始化停充开关 ----
init_stop_switch

sleep "$DELAY"
apply
stop_logic

if [ "$DAEMON" = "1" ]; then
  (
    while true; do
      sleep "$INTERVAL"
      if plugged; then
        apply
        stop_logic
      else
        # 未插充电器：只确保停充开关处于复位态，不写电流节点（避免日志噪音）
        stop_logic
      fi
    done
  ) &
  DPID=$!
  echo "$DPID" > "$PIDFILE"
  log "守护启动 (pid $DPID)，间隔 ${INTERVAL}s"
else
  log "守护关闭（DAEMON=0）"
fi

log "service.sh 结束"
