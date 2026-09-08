#!/bin/bash
# =============================================================
# SCRIPT: hang_probe_v4v.sh  (挂起探针, vllm-v4v-healthcheck.timer 60s 调用)
# ROLE:   head 上探测 8888 /health; 引擎挂起时触发全链重建
# 保护:   两条触发路径, 均含冷启动期 age 保护, 避免 boot 期误杀:
#         (A) 此前健康后挂起: STATE 在本次容器启动之后写过, 且容器 age>=15min
#         (B) boot 盲区:     本次启动从未健康 (STATE 缺失/早于本纪元), 且容器
#                             age>=30min 且近5min日志静默 -> 允许杀 (封 09-07 盲区)
#                          (机器重启后 STATE 必然过期, 原逻辑 probe 永久沉默;
#                           本分支让从未健康的异常 boot 也能被自愈链接管)
# 对齐:   GLM hang_probe_glm53 (容器名与端口改 vision)
# 变更:   2026-09-08 增 boot 分支 (任务2, Claude V4 Pro 分析产出)
# =============================================================
set -u
STATE=~/v4v-test/healthy-state
PORT=8888
NAME="vllm-v4v-tp4-rank0"
LOG=~/crash-logs/hang-probe-v4v.log
mkdir -p ~/crash-logs

# ---- 冷启动保护参数 ----
AGE_HEALTHY_MIN=900      # 路径A: 曾健康场景, 容器 age 下限 (>=15min, 原逻辑)
AGE_BOOT_MIN=1800        # 路径B: boot 盲区场景, 容器 age 下限 (>=30min = 冷启动12min上限x2余量)
LIVELINESS_MAX=5         # 近5min日志行数 <=5 视为"静默" (引擎非忙)

# ---- 当前健康状态 ----
H=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null)

if [ "$H" = "200" ]; then
  touch "$STATE"
  exit 0
fi

# ---- 容器启动纪元 (防 boot 期误杀) ----
START=$(docker inspect --format '{{.State.StartedAt}}' "$NAME" 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null)
[ -z "$START" ] || [ "$START" = "0" ] && { echo "$(date '+%F %T') [v4v-hang-probe] no container/inspect, skip" >> "$LOG"; exit 0; }
NOW=$(date +%s)
AGE=$(( NOW - START ))

# ---- 本次容器启动后是否曾健康: STATE 写于本纪元之后 ----
STATE_TS=0
[ -f "$STATE" ] && STATE_TS=$(stat -c %Y "$STATE")
HEALTHY_THIS_BOOT=0
[ "$STATE_TS" -ge "$START" ] && HEALTHY_THIS_BOOT=1

# ---- 活性保护 (LuZ 超时守卫借鉴): 近5min引擎日志有推进 = 忙不是挂, 不杀 ----
LIVELINESS=$(docker logs --since 5m "$NAME" 2>&1 | wc -l)
QUIET=0
[ "${LIVELINESS:-0}" -le "$LIVELINESS_MAX" ] && QUIET=1

log() { echo "$(date '+%F %T') [v4v-hang-probe] $*" >> "$LOG"; }

# ================= 判定 =================
# 冷启动期 (age 未达下限) 一律不杀防误杀
if [ "$AGE" -lt "$AGE_HEALTHY_MIN" ]; then
  exit 0
fi

# 仅当 "静默" 才认为可能挂起; 有日志推进则等待
if [ "$QUIET" != "1" ]; then
  exit 0
fi

if [ "$HEALTHY_THIS_BOOT" = "1" ]; then
  # 路径A: 本纪元曾健康后面临 /health 非200 且静默 -> 杀
  log "/health=$H, healthy-this-boot, age=${AGE}s, quiet -> kill $NAME (monitor rebuild)"
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 0
fi

if [ "$AGE" -ge "$AGE_BOOT_MIN" ]; then
  # 路径B: boot 盲区 - 本纪元从未健康, 且早已超冷启动期, 且静默 -> 杀
  # (机器重启后 STATE 过期, 原逻辑永久沉默; 此分支让异常 boot 也能触发自愈)
  log "/health=$H, boot-blindspot (never healthy this boot), age=${AGE}s, quiet -> kill $NAME (monitor rebuild)"
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 0
fi

# boot 期或长期未健康但仍在冷启动/日志推进: 不动作, 防误杀
exit 0
