#!/bin/bash
# 温度哨兵 (LuZ/GLM 基准纪律): 60s 采样 GPU 温度到 log, 超阈值告警
set -u
LOG="${1:-/home/<user>/v4v-bench-results/temp-watch.log}"
THRESH="${2:-68}"
echo "$(date '+%F %T') temp-watch start (threshold ${THRESH}C)" >> "$LOG"
while true; do
  T=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
  echo "$(date '+%F %T') gpu=${T}C" >> "$LOG"
  if [ -n "$T" ] && [ "$T" -ge "$THRESH" ]; then
    echo "$(date '+%F %T') [ALARM] gpu=${T}C >= ${THRESH}C" >> "$LOG"
  fi
  sleep 60
done
