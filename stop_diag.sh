#!/system/bin/sh
# ============================================================
#  stop_diag.sh —— 80% 停充功能诊断
#  用法：插着充电器，root 终端执行
#        sh /sdcard/stop_diag.sh 2>&1 | tee /sdcard/stop_result.txt
#  脚本会短暂暂停充电做测试，结束后自动恢复
# ============================================================

say() { echo "$@"; }

say "===== 1. option.txt 里的实际配置 ====="
grep -E '^CHARGE_STOP|^RESUME_AT' /data/adb/modules/slowcharge/option.txt 2>/dev/null
say "(若为空或没输出 = 配置项没写对/被注释了)"
say ""

say "===== 2. 模块日志里的停充记录 ====="
if grep -q '停充' /data/adb/modules/slowcharge/log.txt 2>/dev/null; then
  say "找到停充记录："
  grep -E '停充' /data/adb/modules/slowcharge/log.txt | tail -10
else
  say "!! 从未出现'停充'记录 = 写入失败（脚本里写入失败不记日志）"
fi
say ""
say "--- 最近的恢复记录 ---"
grep -E '恢复' /data/adb/modules/slowcharge/log.txt 2>/dev/null | tail -5
say ""

say "===== 3. 守护进程 ====="
ps -ef | grep slowcharge | grep -v grep
say ""

say "===== 4. 候选停充开关：是否存在 + 当前值 + 权限 ====="
for p in battery_charging_enabled input_suspend charging_enabled \
         charge_disable store_mode batt_slate_mode charge_enabled; do
  f="/sys/class/power_supply/battery/$p"
  if [ -f "$f" ]; then
    perm=$(ls -l "$f" 2>/dev/null | cut -c1-10)
    say "[存在] $p = $(cat $f 2>/dev/null)   $perm"
  fi
done
say ""

say "===== 5. 写入测试：battery_charging_enabled 写 0 ====="
SW=/sys/class/power_supply/battery/battery_charging_enabled
if [ -f "$SW" ]; then
  say "写入前: $(cat $SW)   status=$(cat /sys/class/power_supply/battery/status)"
  say "当前电流: $(cat /sys/class/power_supply/battery/current_now)"
  chmod 0644 "$SW" 2>/dev/null
  if echo 0 > "$SW" 2>/dev/null; then
    say "写入命令: 成功"
  else
    say "写入命令: 失败（只读 / 内核拒绝 / SELinux）"
  fi
  sleep 5
  say "5秒后读回: $(cat $SW)"
  say "status     = $(cat /sys/class/power_supply/battery/status)"
  say "current_now= $(cat /sys/class/power_supply/battery/current_now)"
  say ""
  say "判定：status 变成 Not charging/Discharging 且电流≈0 => 节点有效"
  say "      仍是 Charging 且电流不变 => 节点无效或被覆盖"
  say ""
  say "--- 正在恢复（写回 1）---"
  echo 1 > "$SW" 2>/dev/null
  sleep 2
  say "恢复后: $(cat $SW)   status=$(cat /sys/class/power_supply/battery/status)"
else
  say "!! battery_charging_enabled 不存在"
fi
say ""

say "===== 6. 备选：input_suspend 写入测试 ====="
SW2=/sys/class/power_supply/battery/input_suspend
if [ -f "$SW2" ]; then
  say "当前值: $(cat $SW2)  （此节点是反极性：0=充电, 1=停充）"
  chmod 0644 "$SW2" 2>/dev/null
  ORIG=$(cat "$SW2")
  if echo 1 > "$SW2" 2>/dev/null; then
    say "写入 1: 成功"
  else
    say "写入 1: 失败"
  fi
  sleep 5
  say "5秒后: $(cat $SW2)   status=$(cat /sys/class/power_supply/battery/status)"
  say "current_now= $(cat /sys/class/power_supply/battery/current_now)"
  say ""
  say "--- 正在恢复（写回 $ORIG）---"
  echo "$ORIG" > "$SW2" 2>/dev/null
  sleep 2
  say "恢复后: $(cat $SW2)   status=$(cat /sys/class/power_supply/battery/status)"
else
  say "!! input_suspend 不存在"
fi
say ""

say "===== 7. 其他 power_supply 下的停充类节点 ====="
find /sys/class/power_supply -maxdepth 2 -type f \( \
  -name '*charging_enabled*' -o -name '*suspend*' -o -name '*charge_disable*' \
  -o -name '*store_mode*' -o -name '*slate*' \) 2>/dev/null | while read f; do
  say "$f = $(cat "$f" 2>/dev/null)"
done
say ""

say "===== 完成 ====="
say "结果已保存到 /sdcard/stop_result.txt"
say "把这个文件内容发出来即可。"
