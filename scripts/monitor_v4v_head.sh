#!/bin/bash
# =============================================================
# SCRIPT: monitor_v4v_head.sh  (Vision-Exp TP4 自愈链·head 侧)
# VERSION: v1.0 (2026-09-05)
# ROLE:   head(n1 .55) 上跟随 vllm-v4v-tp4-rank0 容器; 容器退出即全链重建
# 架构:   对齐 GLM monitor_glm53_head (worker 死亡经 NCCL 超时传导到 head 容器退出)
# 启动:   vllm-v4v-head.service ExecStartPost 后台拉起 (nohup)
# 依赖:   ssh n2/03/04 免密 (四机互解析, 维护手册铁律)
# 环序:   .55(rank0) - .56(rank1) - .58(rank2) - .57(rank3)  (物理环序, 勿按尾号排)
# =============================================================
set -u
NAME="vllm-v4v-tp4-rank0"
# worker 节点与 rank: n2=.56=rank1, n4=.58=rank2, n3=.57=rank3
WORKERS=("n3" "n4" "n2")   # 重建顺序 rank3 -> rank2 -> rank1
W_RANKS=(3 2 1)
HEAD_RANK=0
LOG=~/crash-logs/monitor-v4v.log
mkdir -p ~/crash-logs

log() { echo "$(date '+%F %T') [monitor-v4v] $*" >> "$LOG"; }

log "monitor_v4v_head starting, following container $NAME"

capture_all() {
  local tag="$1"
  docker logs "$NAME" > ~/crash-logs/v4v-${tag}-head.log 2>/dev/null || true
  for w in n2 n3 n4; do
    ssh -o ConnectTimeout=5 "$w" "docker logs $NAME > ~/crash-logs/v4v-${tag}-\$(hostname).log 2>/dev/null; docker logs vllm-v4v-tp4-rank1 > ~/crash-logs/v4v-${tag}-r1-\$(hostname).log 2>/dev/null; docker logs vllm-v4v-tp4-rank2 > ~/crash-logs/v4v-${tag}-r2-\$(hostname).log 2>/dev/null; docker logs vllm-v4v-tp4-rank3 > ~/crash-logs/v4v-${tag}-r3-\$(hostname).log 2>/dev/null" || true
  done
  log "forensics captured (tag=$tag)"
}

rebuild_chain() {
  local reason="$1"
  log "REBUILD trigger: $reason"
  capture_all "$(date +%Y%m%d-%H%M%S)"
  # 清四机容器 (换 rank 必四机同周期; worker-first 重建)
  for w in n2 n3 n4; do
    ssh -o ConnectTimeout=5 "$w" "docker rm -f vllm-v4v-tp4-rank1 vllm-v4v-tp4-rank2 vllm-v4v-tp4-rank3" >/dev/null 2>&1 || true
  done
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  sleep 5
  # worker-first: rank3(.57=n3) -> rank2(.58=n4) -> rank1(.56=n2) -> head(.55)
  for i in 0 1 2; do
    local w="${WORKERS[$i]}" r="${W_RANKS[$i]}"
    ssh -o ConnectTimeout=5 "$w" "cd /home/<user>/v4v-test && NODE_RANK=$r NO_WAIT=1 bash start_v4v_worker.sh" >> "$LOG" 2>&1 || true
    sleep 5
  done
  cd /home/<user>/v4v-test && NO_WAIT=1 bash start_v4v_head.sh >> "$LOG" 2>&1 || true
  log "rebuild launched (worker-first 3->2->1->0)"
}

# 主循环: 跟随容器 (崩溃循环退避: 30min 内重建>=3 次则冷却 30min, 防配置错误烧机)
REBUILD_TS=()
LAST_REBUILD=""
while true; do
  docker wait "$NAME" >/dev/null 2>&1
  sleep 5
  # rebuild 期间的 docker rm -f 会让 wait 立即返回: 距上次 rebuild <120s 的退出视为自身噪声
  if [ -n "$LAST_REBUILD" ] && [ $(( $(date +%s) - LAST_REBUILD )) -lt 120 ]; then
    log "ignore exit during rebuild window (LAST_REBUILD=$(date -d @$LAST_REBUILD '+%H:%M:%S' 2>/dev/null || echo $LAST_REBUILD))"
    continue
  fi
  if docker inspect "$NAME" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
    log "container still running, continue following"
    continue
  fi
  now=""; now_ts=""
  now=$(date +%s)
  REBUILD_TS=("${REBUILD_TS[@]: -2}")
  REBUILD_TS+=("$now")
  if [ "${#REBUILD_TS[@]}" -ge 3 ] && [ $((now - REBUILD_TS[0])) -le 1800 ]; then
    log "cooldown: >=3 rebuilds in 30min, sleeping 30min (anti-burn)"
    sleep 1800
    REBUILD_TS=()
    continue
  fi
  rebuild_chain "container exited"
  LAST_REBUILD=$(date +%s)
done
