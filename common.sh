#!/system/bin/sh
# 共用逻辑 v4 —— alioth (Redmi K40)
#
# v4 核心：软停充（trickle）绕开 Android Doze
#
# 【v3 的缺陷】input_suspend=1 -> status 变 Discharging -> Android 进 Doze
#              -> sleep 不推进 -> 守护冻结 -> 停充守不住 -> 充到 100%
#
# 【v4 的解法】到阈值时不断开充电，只把电流降到 TRICKLE_UA
#              -> status 始终 Charging -> 不进 Doze -> 守护永不冻结
#
# 其他修复：
#   - 移除坏节点 main/current_max（实测是实时读数节点，读回值乱跳，写了无效）
#   - 默认区间改为 60/45（长期插电备用机最优）
#
# 安全策略：电流写入值绝不超过 FACTORY_MAX

MODDIR=${0%/*}
OPTION="$MODDIR/option.txt"
LOG="$MODDIR/log.txt"
STATE="$MODDIR/stop_state"

# ---- 默认值 ----
FACTORY_MAX=4920000
CURRENT_UA=3000000
TRICKLE_UA=150000
USB_UA=1500000
STOP_MODE=trickle
ANTI_DOZE=0
DAEMON=1
INTERVAL=30
DELAY=20
CHARGE_STOP=0
RESUME_AT=0

[ -f "$OPTION" ] && . "$OPTION"

num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
FACTORY_MAX=$(num "$FACTORY_MAX" 4920000)
CURRENT_UA=$(num "$CURRENT_UA" 2000000)
TRICKLE_UA=$(num "$TRICKLE_UA" 150000)
USB_UA=$(num "$USB_UA" 0)
ANTI_DOZE=$(num "$ANTI_DOZE" 0)
INTERVAL=$(num "$INTERVAL" 30)
DELAY=$(num "$DELAY" 20)
CHARGE_STOP=$(num "$CHARGE_STOP" 0)
RESUME_AT=$(num "$RESUME_AT" 0)

[ "$INTERVAL" -lt 15 ] && INTERVAL=15
[ "$CURRENT_UA" -gt "$FACTORY_MAX" ] && CURRENT_UA=$FACTORY_MAX
[ "$TRICKLE_UA" -gt "$FACTORY_MAX" ] && TRICKLE_UA=$FACTORY_MAX
[ "$STOP_MODE" != "suspend" ] && STOP_MODE=trickle
if [ "$CHARGE_STOP" -ne 0 ] && [ "$RESUME_AT" -ge "$CHARGE_STOP" ]; then
  RESUME_AT=$((CHARGE_STOP - 5))
fi

log() { echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }

if [ -f "$LOG" ]; then
  LINES=$(wc -l < "$LOG" 2>/dev/null)
  LINES=$(num "$LINES" 0)
  [ "$LINES" -gt 300 ] && { tail -80 "$LOG" > "$LOG.tmp"; mv "$LOG.tmp" "$LOG"; }
fi

rd() { cat "$1" 2>/dev/null; }

# ============================================================
#  电池端限流节点
#  注：main/current_max 已从列表中移除（实测为实时读数节点，
#      写入后读回值在 0 / 1550000 / 2750000 之间乱跳，无效且制造噪音）
# ============================================================
BAT_PATHS="
/sys/class/power_supply/battery/constant_charge_current_max
/sys/class/power_supply/battery/constant_charge_current
/sys/class/power_supply/main/constant_charge_current_max
/sys/class/power_supply/bms/constant_charge_current_max
/sys/class/power_supply/bq2597x-standalone/constant_charge_current_max
/sys/class/power_supply/main-charger/constant_charge_current_max
"

USB_PATHS="
/sys/class/power_supply/usb/pd_current_max
/sys/class/power_supply/usb/current_max
/sys/class/power_supply/usb/input_current_limit
"

# 当前应写入的电流值（由 calc_target 计算）
EFFECTIVE_UA=$CURRENT_UA

# ---------- 停充状态（迟滞）----------
read_state() { [ -f "$STATE" ] && rd "$STATE" || echo 0; }
write_state() { echo "$1" > "$STATE"; }

# 计算当前应该写入的电流
calc_target() {
  EFFECTIVE_UA=$CURRENT_UA
  [ "$CHARGE_STOP" -eq 0 ] && return 0

  CAP=$(rd /sys/class/power_supply/battery/capacity)
  case "$CAP" in ''|*[!0-9]*) return 0 ;; esac

  ST=$(read_state)

  if [ "$CAP" -ge "$CHARGE_STOP" ]; then
    if [ "$ST" != "1" ]; then
      write_state 1
      log "软停充: 电量 ${CAP}% >= ${CHARGE_STOP}%，电流 ${CURRENT_UA} -> ${TRICKLE_UA} uA"
    fi
    EFFECTIVE_UA=$TRICKLE_UA
  elif [ "$CAP" -le "$RESUME_AT" ]; then
    if [ "$ST" != "0" ]; then
      write_state 0
      log "恢复充电: 电量 ${CAP}% <= ${RESUME_AT}%，电流 ${TRICKLE_UA} -> ${CURRENT_UA} uA"
    fi
    EFFECTIVE_UA=$CURRENT_UA
  else
    # 迟滞区间，保持原状态
    if [ "$ST" = "1" ]; then
      EFFECTIVE_UA=$TRICKLE_UA
    else
      EFFECTIVE_UA=$CURRENT_UA
    fi
  fi
  return 0
}

# ---------- 硬停充（suspend 模式）----------
STOP_SW=""
STOP_ON=0
STOP_OFF=1

init_stop_switch() {
  [ "$STOP_MODE" != "suspend" ] && return 1
  [ "$CHARGE_STOP" -eq 0 ] && return 1

  CAND="
/sys/class/power_supply/battery/input_suspend
/sys/class/power_supply/battery/battery_charging_enabled
/sys/class/power_supply/battery/charging_enabled
/sys/class/power_supply/battery/charge_disable
"
  for p in $CAND; do
    [ -f "$p" ] || continue
    orig=$(rd "$p")
    case "$orig" in ''|*[!0-9]*) continue ;; esac
    chmod 0644 "$p" 2>/dev/null
    if echo "$orig" > "$p" 2>/dev/null; then
      STOP_SW="$p"
      case "$p" in
        *input_suspend|*charge_disable) STOP_ON=0; STOP_OFF=1 ;;
        *)                              STOP_ON=1; STOP_OFF=0 ;;
      esac
      log "硬停充开关: $p (充电=$STOP_ON 停充=$STOP_OFF)"
      return 0
    fi
  done
  log "!! 未找到可用硬停充开关，suspend 模式不可用"
  return 1
}

# ---------- Doze 防护（仅 suspend 模式）----------
LOCK_NAME="slowcharge"
lock_held=0

acquire_lock() {
  [ "$ANTI_DOZE" -lt 1 ] && return 0
  if [ -w /sys/power/wake_lock ]; then
    echo "$LOCK_NAME" > /sys/power/wake_lock 2>/dev/null && lock_held=1
  fi
  [ "$ANTI_DOZE" -ge 2 ] && dumpsys deviceidle disable >/dev/null 2>&1
  return 0
}

release_lock() {
  [ "$lock_held" = "1" ] && {
    echo "$LOCK_NAME" > /sys/power/wake_unlock 2>/dev/null
    lock_held=0
  }
  [ "$ANTI_DOZE" -ge 2 ] && dumpsys deviceidle enable >/dev/null 2>&1
  return 0
}

# 充电器是否插入
plugged() {
  for p in /sys/class/power_supply/usb/present \
           /sys/class/power_supply/usb/online \
           /sys/class/power_supply/typec/present \
           /sys/class/power_supply/ac/online; do
    if [ -f "$p" ]; then
      v=$(rd "$p")
      case "$v" in ''|*[!0-9]*) ;; *) [ "$v" -ne 0 ] && return 0; return 1 ;; esac
    fi
  done
  ST=$(rd /sys/class/power_supply/battery/status)
  case "$ST" in *Discharging*) return 1 ;; *) return 0 ;; esac
}

# ---------- 写入 ----------
set_bat() {
  p="$1"; t="$2"
  [ -f "$p" ] || return 1
  cur=$(rd "$p")
  case "$cur" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$cur" -lt 0 ] && return 1
  [ "$t" -gt "$FACTORY_MAX" ] && { log "SKIP 目标 $t 超过出厂上限 $FACTORY_MAX"; return 1; }
  [ "$t" -eq "$cur" ] && return 0

  chmod 0644 "$p" 2>/dev/null
  if echo "$t" > "$p" 2>/dev/null; then
    sleep 1
    now=$(rd "$p")
    [ "$now" -eq "$t" ] 2>/dev/null \
      && log "OK   [BAT] $p: $cur -> $t (保持)" \
      || log "WARN [BAT] $p: 写入 $t 读回 $now（被覆盖）"
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
  echo "$t" > "$p" 2>/dev/null && log "OK   [USB] $p: $cur -> $t" \
                              || log "FAIL [USB] $p: 写入失败（当前 $cur）"
}

# ---------- 主应用逻辑 ----------
apply() {
  calc_target

  # 硬停充模式：同步开关
  if [ "$STOP_MODE" = "suspend" ] && [ -n "$STOP_SW" ] && [ -f "$STOP_SW" ]; then
    if [ "$EFFECTIVE_UA" = "$TRICKLE_UA" ] && [ "$CHARGE_STOP" -ne 0 ]; then
      want=$STOP_OFF; release_lock
    else
      want=$STOP_ON
    fi
    cur=$(rd "$STOP_SW")
    [ "$cur" != "$want" ] && echo "$want" > "$STOP_SW" 2>/dev/null
    if [ "$want" = "$STOP_OFF" ]; then acquire_lock; else release_lock; fi
  fi

  HIT=0
  for p in $BAT_PATHS; do
    [ -f "$p" ] || continue
    set_bat "$p" "$EFFECTIVE_UA" && HIT=1
  done

  if [ "$USB_UA" -gt 0 ]; then
    for p in $USB_PATHS; do
      [ -f "$p" ] || continue
      set_usb "$p" "$USB_UA"
    done
  fi

  [ "$HIT" -eq 0 ] && log "!! 未找到任何可写电池端节点"

  # 失控兜底：电量远超阈值却仍在快充，强制纠正并记录
  if [ "$CHARGE_STOP" -ne 0 ]; then
    CAP=$(rd /sys/class/power_supply/battery/capacity)
    LIMIT=$((CHARGE_STOP + 5))
    if [ "$CAP" -gt "$LIMIT" ] 2>/dev/null && [ "$EFFECTIVE_UA" != "$TRICKLE_UA" ]; then
      log "!! 失控警告: 电量 ${CAP}% > ${LIMIT}% 仍在 ${EFFECTIVE_UA}uA，强制切涓流"
      write_state 1
    fi
  fi
}
