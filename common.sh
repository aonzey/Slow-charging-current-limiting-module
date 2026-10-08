#!/system/bin/sh
# 共用逻辑 v3 —— alioth (Redmi K40) 实测调整
#
# v3 关键修复：
#   1. 停充开关改用 input_suspend（battery_charging_enabled 在本机是假开关）
#      并逐个验证可写性，不再盲选
#   2. 停充逻辑不再依赖 battery/status（停充后 status 变 Discharging）
#      改用 usb/present 判断充电器是否插入
#   3. 拔掉充电器时自动复位停充开关，避免"拔了再插充不进"
#
# 安全策略：电流写入值绝不超过 FACTORY_MAX

MODDIR=${0%/*}
OPTION="$MODDIR/option.txt"
LOG="$MODDIR/log.txt"

# ---- 默认值 ----
FACTORY_MAX=4920000
CURRENT_UA=3000000
USB_UA=1500000
DAEMON=1
INTERVAL=30
DELAY=20
CHARGE_STOP=0
RESUME_AT=0

[ -f "$OPTION" ] && . "$OPTION"

num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
FACTORY_MAX=$(num "$FACTORY_MAX" 4920000)
CURRENT_UA=$(num "$CURRENT_UA" 2000000)
USB_UA=$(num "$USB_UA" 0)
INTERVAL=$(num "$INTERVAL" 30)
DELAY=$(num "$DELAY" 20)
CHARGE_STOP=$(num "$CHARGE_STOP" 0)
RESUME_AT=$(num "$RESUME_AT" 0)

[ "$INTERVAL" -lt 15 ] && INTERVAL=15
[ "$CURRENT_UA" -gt "$FACTORY_MAX" ] && CURRENT_UA=$FACTORY_MAX
if [ "$CHARGE_STOP" -ne 0 ] && [ "$RESUME_AT" -ge "$CHARGE_STOP" ]; then
  RESUME_AT=$((CHARGE_STOP - 5))
fi

log() { echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }

# 日志截断
if [ -f "$LOG" ]; then
  LINES=$(wc -l < "$LOG" 2>/dev/null)
  LINES=$(num "$LINES" 0)
  [ "$LINES" -gt 300 ] && { tail -80 "$LOG" > "$LOG.tmp"; mv "$LOG.tmp" "$LOG"; }
fi

rd() { cat "$1" 2>/dev/null; }

# ============================================================
#  电池端限流节点（实测优先级）
# ============================================================
BAT_PATHS="
/sys/class/power_supply/battery/constant_charge_current_max
/sys/class/power_supply/main/constant_charge_current_max
/sys/class/power_supply/main/current_max
/sys/class/power_supply/battery/current_max
/sys/class/power_supply/bms/constant_charge_current_max
/sys/class/power_supply/bq2597x-standalone/constant_charge_current_max
/sys/class/power_supply/main-charger/current_max
/sys/class/power_supply/main-charger/constant_charge_current_max
"

USB_PATHS="
/sys/class/power_supply/usb/current_max
/sys/class/power_supply/usb/input_current_limit
/sys/class/power_supply/usb/pd_current_max
/sys/class/power_supply/typec/current_max
"

set_bat() {
  p="$1"; t="$2"
  [ -f "$p" ] || return 1
  cur=$(rd "$p")
  case "$cur" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$cur" -lt 0 ] && return 1
  if [ "$t" -gt "$FACTORY_MAX" ]; then
    log "SKIP [BAT] 目标 $t 超过出厂上限 $FACTORY_MAX，已拒绝"
    return 1
  fi
  [ "$t" -eq "$cur" ] && return 0
  chmod 0644 "$p" 2>/dev/null
  if echo "$t" > "$p" 2>/dev/null; then
    sleep 1
    now=$(rd "$p")
    if [ "$now" -eq "$t" ] 2>/dev/null; then
      log "OK   [BAT] $p: $cur -> $t (保持)"
    else
      log "WARN [BAT] $p: 写入 $t 但读回 $now（被覆盖）"
    fi
    return 0
  else
    log "FAIL [BAT] $p: 写入失败（当前 $cur）"
    return 1
  fi
}

set_usb() {
  p="$1"; t="$2"
  [ -f "$p" ] || return 1
  cur=$(rd "$p")
  case "$cur" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$cur" -lt 0 ] && return 1
  [ "$t" -ge "$cur" ] && return 0
  chmod 0644 "$p" 2>/dev/null
  if echo "$t" > "$p" 2>/dev/null; then
    log "OK   [USB] $p: $cur -> $t"
  else
    log "FAIL [USB] $p: 写入失败（当前 $cur）"
  fi
}

apply() {
  HIT=0
  for p in $BAT_PATHS; do
    [ -f "$p" ] || continue
    set_bat "$p" "$CURRENT_UA" && HIT=1
  done
  if [ "$USB_UA" -gt 0 ]; then
    for p in $USB_PATHS; do
      [ -f "$p" ] || continue
      set_usb "$p" "$USB_UA"
    done
  fi
  [ "$HIT" -eq 0 ] && log "!! 未找到任何可写电池端节点"
}

# ============================================================
#  停充开关（v3 重写）
# ============================================================
# 实测结论（alioth）：
#   battery_charging_enabled —— 能写但内核不认，写 0 后仍在 Charging  => 弃用
#   input_suspend            —— 写 1 后 status 变 Discharging，真停充  => 采用
#   input_suspend 是反极性：0 = 充电，1 = 停充

STOP_SW=""
STOP_ON=0    # 允许充电时写入的值
STOP_OFF=1   # 停止充电时写入的值

init_stop_switch() {
  [ "$CHARGE_STOP" -eq 0 ] && return 1

  # 按实测有效性排序，先试 input_suspend
  CAND="
/sys/class/power_supply/battery/input_suspend
/sys/class/power_supply/battery/battery_charging_enabled
/sys/class/power_supply/battery/charging_enabled
/sys/class/power_supply/battery/charge_disable
"
  for p in $CAND; do
    [ -f "$p" ] || continue
    # 验证可写：读原值 -> 写回原值，确认能落盘
    orig=$(rd "$p")
    case "$orig" in ''|*[!0-9]*) continue ;; esac
    chmod 0644 "$p" 2>/dev/null
    if echo "$orig" > "$p" 2>/dev/null; then
      STOP_SW="$p"
      case "$p" in
        *input_suspend) STOP_ON=0;  STOP_OFF=1 ;;
        *charge_disable) STOP_ON=0;  STOP_OFF=1 ;;
        *)               STOP_ON=1;  STOP_OFF=0 ;;
      esac
      log "停充开关: $p (充电=$STOP_ON 停充=$STOP_OFF)"
      return 0
    fi
  done
  log "!! 未找到可用的停充开关，停充功能不可用"
  return 1
}

# 充电器是否插入（不依赖 battery/status，因为停充后它会变 Discharging）
plugged() {
  for p in /sys/class/power_supply/usb/present \
           /sys/class/power_supply/usb/online \
           /sys/class/power_supply/typec/present \
           /sys/class/power_supply/ac/online \
           /sys/class/power_supply/main-charger/present; do
    if [ -f "$p" ]; then
      v=$(rd "$p")
      case "$v" in ''|*[!0-9]*) ;; *) [ "$v" -ne 0 ] && return 0; return 1 ;; esac
    fi
  done
  # 没有可用节点时退化为看 status，避免误判
  ST=$(rd /sys/class/power_supply/battery/status)
  case "$ST" in *Discharging*) return 1 ;; *) return 0 ;; esac
}

# 停充控制（每次守护循环都执行，与 status 解耦）
stop_logic() {
  [ "$CHARGE_STOP" -eq 0 ] && return 0
  [ -z "$STOP_SW" ] && { init_stop_switch || return 0; }
  [ -f "$STOP_SW" ] || return 0

  if ! plugged; then
    # 拔掉充电器：复位开关，防止下次插入时不充电
    cur=$(rd "$STOP_SW")
    if [ "$cur" != "$STOP_ON" ]; then
      echo "$STOP_ON" > "$STOP_SW" 2>/dev/null && log "复位: 充电器已拔出，恢复充电开关"
    fi
    return 0
  fi

  CAP=$(rd /sys/class/power_supply/battery/capacity)
  case "$CAP" in ''|*[!0-9]*) return 0 ;; esac

  cur=$(rd "$STOP_SW")
  if [ "$CAP" -ge "$CHARGE_STOP" ] && [ "$cur" != "$STOP_OFF" ]; then
    echo "$STOP_OFF" > "$STOP_SW" 2>/dev/null && log "停充: 电量 ${CAP}% >= ${CHARGE_STOP}%"
  elif [ "$cur" = "$STOP_OFF" ] && [ "$CAP" -le "$RESUME_AT" ]; then
    echo "$STOP_ON" > "$STOP_SW" 2>/dev/null && log "恢复: 电量 ${CAP}% <= ${RESUME_AT}%"
  fi
}
