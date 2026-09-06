#!/bin/bash
# =============================================================
# SCRIPT: hang_probe_v4v.sh  (挂起探针, vllm-v4v-healthcheck.timer 60s 调用)
# ROLE:   head 上探测 8890 /health; 引擎挂起时触发全链重建
# 保护:   仅当引擎此前已健康 (state 文件 30min 内) 才触发, 避免 boot 期误杀
# 对齐:   GLM hang_probe_glm53 (容器名与端口改 vision)
# =============================================================
set -u
STATE=~/v4v-test/healthy-state
PORT=8888

H=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null)

if [ "$H" = "200" ]; then
  touch "$STATE"
  exit 0
fi

# health 非 200: 「此前健康」+「容器已运行 >=15min (非冷启动期)」才杀
# 容器年龄保护: 重建后的冷启动期 (~12min) health 必为 000, 不保护会被 probe 反复杀 -> 与 monitor 重建死循环 (2026-09-05 演练实证)
AGE=$(docker inspect --format '{{.State.StartedAt}}' vllm-v4v-tp4-rank0 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null)
# 活性保护 (LuZ 超时守卫借鉴): 近 5min 引擎日志有推进 = 忙不是挂, 不杀
LIVELINESS=$(docker logs --since 5m vllm-v4v-tp4-rank0 2>&1 | wc -l)
if [ -f "$STATE" ] && [ $(( $(date +%s) - $(stat -c %Y "$STATE") )) -lt 1800 ] && [ -n "$AGE" ] && [ $(( $(date +%s) - AGE )) -ge 900 ] && [ "${LIVELINESS:-0}" -le 5 ]; then
  echo "$(date '+%F %T') [v4v-hang-probe] /health=$H -> kill vllm-v4v-tp4-rank0 (monitor will rebuild)" >> ~/crash-logs/hang-probe-v4v.log
  docker rm -f vllm-v4v-tp4-rank0 >/dev/null 2>&1
  # monitor 的 docker wait 醒来即全链重建
else
  # boot 期或长期未健康: 不动作, 防误杀
  exit 0
fi
