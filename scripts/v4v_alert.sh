#!/bin/bash
# =============================================================
# SCRIPT: v4v_alert.sh  (健康/自愈告警闭环, vllm-v4v-alert.timer 60s 调用, head 侧)
# ROLE:   聚合四路集群健康信号, 检测到异常时写持久化告警状态 + 可选 webhook 外发
# 目的:   封堵 09-07 事故暴露的「健康态残留 → 探针失明 → 无人感知」SEV2 缺口。
#         (当时 /health 崩溃前一直 200, 自愈链探针未触发, 外部也无任何告警)
# 触发信号:
#   S1 容器不健康连续 FAIL: docker Inspect State.Health.Status=unhealthy 且
#      FailingStreak>=3 (约3min) 且容器 age>=15min (排除重建冷启动期假阴性)
#   S2 挂起探针触发:   hang-probe-v4v.log 近 70s 有 "kill" 条目 (探针判定挂起->重建)
#   S3 自愈链重建:     monitor-v4v.log 近 70s 有 "REBUILD trigger" 条目
#   S4 温度哨兵报警:   temp-watch.log 近 70s 有 "[ALARM]" 条目
# 外发:   仅当 V4V_ALERT_WEBHOOK 已配置才 POST (JSON); 否则仅落状态/日志, 无副作用
# 变更:   2026-09-08 新增 (任务3, Claude V4 Pro 分析产出)
# =============================================================
set -u
NAME="vllm-v4v-tp4-rank0"
STATE=~/v4v-test/healthy-state
STATUS=~/crash-logs/v4v-alert.status
LOG=~/crash-logs/v4v-alert.log
mkdir -p ~/crash-logs

# 时间窗口 (秒): 探针/monitor/哨兵日志在此窗口内有新条目视为"本次触发"
WINDOW=70
NOW=$(date +%s)

log() { echo "$(date '+%F %T') [v4v-alert] $*" >> "$LOG"; }

# ---- 容器 age (排除重建冷启动期的假阳性) ----
START=$(docker inspect --format '{{.State.StartedAt}}' "$NAME" 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null)
AGE=0
[ -n "$START" ] && [ "$START" != "0" ] && AGE=$(( NOW - START ))
AGE_OK=0
[ "$AGE" -ge 900 ] && AGE_OK=1

# ---- S1 容器不健康连续 FAIL (Docker 原生探针 hc_v4v.sh) ----
S1=0
HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null)
FAILSTREAK=$(docker inspect --format '{{.State.Health.FailingStreak}}' "$NAME" 2>/dev/null)
[ "${FAILSTREAK:-0}" -ge 3 ] && [ "$HEALTH" = "unhealthy" ] && [ "$AGE_OK" = "1" ] && S1=1

# ---- S2 挂起探针触发 ----
S2=0
if [ -f ~/crash-logs/hang-probe-v4v.log ]; then
  LAST2=$(stat -c %Y ~/crash-logs/hang-probe-v4v.log 2>/dev/null || echo 0)
  [ -n "$LAST2" ] && [ $(( NOW - LAST2 )) -le "$WINDOW" ] && \
    grep -q "kill" ~/crash-logs/hang-probe-v4v.log && S2=1
fi

# ---- S3 自愈链重建 ----
S3=0
if [ -f ~/crash-logs/monitor-v4v.log ]; then
  LAST3=$(stat -c %Y ~/crash-logs/monitor-v4v.log 2>/dev/null || echo 0)
  [ -n "$LAST3" ] && [ $(( NOW - LAST3 )) -le "$WINDOW" ] && \
    tail -n 30 ~/crash-logs/monitor-v4v.log | grep -q "REBUILD trigger" && S3=1
fi

# ---- S4 温度哨兵报警 ----
S4=0
TEMP_LOG="${V4V_TEMP_LOG:-/home/<user>/v4v-bench-results/temp-watch.log}"
if [ -f "$TEMP_LOG" ]; then
  LAST4=$(stat -c %Y "$TEMP_LOG" 2>/dev/null || echo 0)
  [ -n "$LAST4" ] && [ $(( NOW - LAST4 )) -le "$WINDOW" ] && \
    tail -n 10 "$TEMP_LOG" | grep -q "\[ALARM\]" && S4=1
fi

# ---- 聚合 ----
TRIGGERS=""
[ "$S1" = "1" ] && TRIGGERS="${TRIGGERS} S1(unhealthy-FailingStreak=$FAILSTREAK age=${AGE}s)"
[ "$S2" = "1" ] && TRIGGERS="${TRIGGERS} S2(hang-probe-kill)"
[ "$S3" = "1" ] && TRIGGERS="${TRIGGERS} S3(monitor-rebuild)"
[ "$S4" = "1" ] && TRIGGERS="${TRIGGERS} S4(temp-ALARM)"

if [ -z "$TRIGGERS" ]; then
  # 全部信号正常: 若有未清告警, 记录一次"已恢复"
  if [ -f "$STATUS" ]; then
    log "ALL CLEAR, previous alert cleared"
    rm -f "$STATUS" 2>/dev/null || true
  fi
  exit 0
fi

# 去重: 同一触发信号已处于 ALERT 状态时不重复外发 (防 60s 刷屏)
ALERT_TS=0
[ -f "$STATUS" ] && ALERT_TS=$(stat -c %Y "$STATUS" 2>/dev/null || echo 0)
DEDUP=0
[ -n "$ALERT_TS" ] && [ $(( NOW - ALERT_TS )) -lt 1800 ] && DEDUP=1

# 写持久化告警状态 (供 DSC/intake 巡检与人工确认)
printf 'ALERT\nlast=%s\ntriggers=%s\nhealth=%s failing_streak=%s age=%ss\n' \
  "$(date '+%F %T')" "$TRIGGERS" "$HEALTH" "${FAILSTREAK:-0}" "$AGE" > "$STATUS"
log "ALERT: ${TRIGGERS} (dedup=${DEDUP}) health=${HEALTH} failing_streak=${FAILSTREAK:-0}"

# 可选 webhook 外发 (仅配置了才发; 未配置则只落状态/日志)
if [ -n "${V4V_ALERT_WEBHOOK:-}" ] && [ "$DEDUP" != "1" ]; then
  PAYLOAD=$(printf '{"ts":"%s","level":"%s","msg":"%s","health":"%s","failing_streak":"%s"}' \
    "$(date '+%F %T')" "SEV2" "v4v-alert: ${TRIGGERS}" "$HEALTH" "${FAILSTREAK:-0}")
  curl -sf --max-time 8 -X POST -H 'Content-Type: application/json' \
    -d "$PAYLOAD" "$V4V_ALERT_WEBHOOK" -o /dev/null 2>/dev/null \
    && log "webhook sent (${TRIGGERS})" \
    || log "webhook failed (skipped, status/log retained)"
fi

exit 0
