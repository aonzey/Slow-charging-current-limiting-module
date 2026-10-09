#!/system/bin/sh
# 开机完成后再写一次：小米 mi_thermald / 充电守护进程
# 多在这个时点之后启动，会把节点改回默认值

MODDIR=${0%/*}
. "$MODDIR/common.sh"

sleep 8
log "===== boot-completed 补写 ====="
[ "$STOP_MODE" = "suspend" ] && init_stop_switch
apply
