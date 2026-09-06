#!/bin/bash
# =============================================================
# SCRIPT: start_v4v_head.sh  (DeepSeek-V4-Flash-Vision-Exp 测试 lane)
# VERSION: v0.1 (2026-09-05)
# ROLE: head(rank0) 启动 — n1 (${N1_IP}), 服务 :8888
# 上游配方: tonyd2wild/DeepSeek-v4-Flash-Vision-Exp-DSpark-1M-NVFP4-KV-2x-DGX-Spark
#           launchers/ds4-vision-tp4.sh (TP4, 2026-09-02 验证, k=5, seqs 64)
# 环网适配: 本环境 LuZ0.4.5 生产环网 env 块 (GID=-1 / PEER_HCA per-rank /
#           SUBNET_AWARE_ROUTING=1 / ring-only 2.30.7 + ncclpin v9 LD_PRELOAD)
# 镜像:    ghcr.io/tonyd2wild/vllm-dspark-runtime:mia-raf-pr1-nvfp4-probe-c-keys-concurrency-p2b
#           (回退: 本机 vllm-dspark-runtime:dspark-nvfp4-stage-c, 同 vLLM 版本)
# 前置:    /var/tmp 六个补丁文件 (build-ds4v-files.sh + recipe/overlay 两个),
#           模型 /home/<user>/models/DeepSeek-V4-Flash-Vision-Exp
# 启动顺序: worker 3→2→1 后 head 0 (Tony 验证顺序; 与生产 head-first 相反)
# =============================================================
set -euo pipefail
export HOME="/home/<user>"

[ "$(hostname)" = "n1" ] || { echo "ERROR: 本脚本仅可在 n1 运行" >&2; exit 1; }

IMG="${V4V_IMG:-ghcr.io/tonyd2wild/vllm-dspark-runtime:mia-raf-pr1-nvfp4-probe-c-keys-concurrency-p2b}"
NAME="vllm-v4v-tp4-rank0"
MODEL_DIR="/home/<user>/models/DeepSeek-V4-Flash-Vision-Exp"
MASTER_ADDR="${N1_IP}"          # 管理网 IP (bootstrap), collective 走 RoCE 环
MASTER_PORT="25998"                  # 独立于生产 25999
NODE_RANK=0
HOST_IP="${N1_IP}"

# ---- 前置检查 (fail-closed) ----
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "ERROR: 镜像缺失 $IMG" >&2; exit 2; }
# gid_preflight (LuZ 0.4.5 借鉴): 内核 1031 后对端断电会让 GID 全零 -> NCCL 建链失败
for p in rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1; do
  g="/sys/class/infiniband/$p/ports/1/gids/0"
  if [ -f "$g" ] && grep -qE '^0{32}$' "$g"; then echo "ERROR: $p GID 全零 (对端断电/NM 撤 IP?)" >&2; exit 5; fi
done
[ -d "$MODEL_DIR" ] || { echo "ERROR: 模型缺失 $MODEL_DIR" >&2; exit 3; }
for f in patch3-scheduler.py spec-dspark.py ds4v_model.py ds4v_vision.py ds4v_mm.py ds4v_registry.py; do
  [ -f "/var/tmp/$f" ] || { echo "ERROR: 缺补丁文件 /var/tmp/$f (先在 head 跑 build-ds4v-files.sh 并分发)" >&2; exit 4; }
done

SERVE_CMD="unset NCCL_IB_ADDR_RANGE NCCL_IB_ADDR_FAMILY NCCL_IB_ROCE_VERSION_NUM NCCL_P2P_DISABLE NCCL_IB_DISABLE NCCL_NVLS_ENABLE NCCL_CUMEM_ENABLE NCCL_IB_GID_INDEX; export PATH=\"/opt/env/bin:/opt/env/nvvm/bin:/opt/env/targets/sbsa-linux/nvvm/bin:\${PATH:-}\";
    export CUDA_HOME=\"\${CUDA_HOME:-/opt/env/targets/sbsa-linux}\";
    export CUDA_PATH=\"\${CUDA_PATH:-\${CUDA_HOME}}\";
    export CUDAToolkit_ROOT=\"\${CUDAToolkit_ROOT:-\${CUDA_HOME}}\";
    export LD_LIBRARY_PATH=\"/opt/env/lib:/opt/env/targets/sbsa-linux/lib:\${LD_LIBRARY_PATH:-}\";
    exec /opt/env/bin/vllm serve /models \
      --hf-overrides '{\"architectures\":[\"DeepseekV4VForConditionalGeneration\"]}' \
      --served-model-name deepseek-v4-flash-vision-exp \
      --host 0.0.0.0 --port 8888 \
      --trust-remote-code \
      --tensor-parallel-size 4 --pipeline-parallel-size 1 \
      --kv-cache-dtype nvfp4_ds_mla \
      --block-size 256 \
      --max-model-len 1048576 \
      --max-num-seqs 64 \
      --max-num-batched-tokens 8192 \
      --max-cudagraph-capture-size 64 \
      --gpu-memory-utilization 0.82 \
      --enable-prefix-caching \
      --async-scheduling \
      --enable-chunked-prefill \
      --speculative-config '{\"method\":\"dspark\",\"num_speculative_tokens\":5,\"draft_sample_method\":\"probabilistic\"}' \
      --tokenizer-mode deepseek_v4 \
      --distributed-executor-backend mp \
      --tool-call-parser deepseek_v4 --enable-auto-tool-choice \
      --reasoning-parser deepseek_v4 \
      --reasoning-config '{\"reasoning_parser\":\"deepseek_v4\",\"reasoning_start_str\":\"<think>\",\"reasoning_end_str\":\"</think>\"}' \
      --default-chat-template-kwargs '{\"thinking\":false}' \
      --generation-config vllm \
      --enable-flashinfer-autotune \
      --nnodes 4 --node-rank $NODE_RANK --master-addr $MASTER_ADDR --master-port $MASTER_PORT"

ENV_ARGS=(
  # ---- 引擎 env (Tony launcher 验证集, 勿删) ----
  -e 'DSPARK_SLOT_CLAMP=1'
  -e 'MTP_NUM_TOKENS=5'
  -e 'VLLM_ALLOW_LONG_MAX_MODEL_LEN=1'
  -e 'VLLM_DISABLE_PYNCCL=1'
  -e 'VLLM_TRITON_MLA_SPARSE=1'
  -e 'VLLM_SPARSE_INDEXER_MAX_LOGITS_MB=256'
  -e 'VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0'
  -e 'VLLM_SKIP_INIT_MEMORY_CHECK=1'
  -e 'VLLM_USE_FLASHINFER_SAMPLER=1'
  -e 'VLLM_USE_B12X_MOE=1'
  -e 'VLLM_USE_B12X_WO_PROJECTION=1'
  -e 'VLLM_B12X_W4A16_FORCE_BLOCKS_PER_SM=0'
  -e 'VLLM_B12X_W4A16_FORCE_BLOCKS_MAX_M=16'
  -e 'B12X_W4A16_TC_DECODE=0'
  -e 'VLLM_DSPARK_CONFIDENCE_THRESHOLD=0.0'
  -e 'VLLM_DSPARK_CONFIDENCE_SCHEDULER=off'
  -e 'VLLM_DSPARK_LOCAL_ARGMAX=1'
  -e 'VLLM_DSPARK_REPLICATE_MARKOV_W1=1'
  -e 'VLLM_DSPARK_FUSED_MARKOV_ARGMAX=0'
  -e 'VLLM_DSPARK_GPU_REJECTED_CONTEXT_MASK=1'
  -e 'VLLM_DSPARK_REFERENCE_KV_QUANT_DEQUANT=0'
  -e 'VLLM_DSPARK_HARDWARE_SCHEDULER_EARLY_STOP=1'
  -e 'VLLM_DSV4_B12X_COMPRESSED_MLA=0'
  -e 'VLLM_DSV4_DSPARK_DEFER_TARGET_CAPTURE=0'
  -e 'VLLM_DSV4_DSPARK_DEFER_TARGET_CAPTURE_EXACT=0'
  -e 'TORCH_CUDA_ARCH_LIST=12.1a'
  -e 'FLASHINFER_CUDA_ARCH_LIST=12.1a'
  -e 'FLASHINFER_DISABLE_VERSION_CHECK=1'
  -e 'TILELANG_CLEANUP_TEMP_FILES=1'
  -e 'DG_JIT_USE_NVRTC=0'
  -e 'DG_JIT_NVCC_COMPILER=/opt/env/bin/nvcc'
  -e 'PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True'
  -e 'VLLM_ENGINE_READY_TIMEOUT_S=3600'
  -e 'HF_HOME=/cache/huggingface'
  -e 'HF_HUB_OFFLINE=1'
  -e 'TRANSFORMERS_OFFLINE=1'
  -e 'HF_HUB_DISABLE_XET=1'
  -e 'VLLM_CACHE_ROOT=/vllm-cache'
  -e 'VLLM_FLASHINFER_AUTOTUNE_CACHE_DIR=/vllm-cache/autotune'
  -e 'DG_JIT_CACHE_DIR=/vllm-cache/deepgemm-cache'
  -e 'FLASHINFER_WORKSPACE_BASE=/vllm-cache/flashinfer'
  -e 'TILELANG_CACHE_DIR=/vllm-cache/tilelang'
  -e 'TORCHINDUCTOR_CACHE_DIR=/vllm-cache/torchinductor-cache'
  -e 'TRITON_CACHE_DIR=/vllm-cache/triton-cache'
  -e 'TORCH_EXTENSIONS_DIR=/vllm-cache/torch_extensions'
  # ---- 环网 env (生产 v2.0-luz045-r1 同源; 本环境定制勿改) ----
  -e 'CUDA_DEVICE_ORDER=PCI_BUS_ID'
  -e 'CUDA_VISIBLE_DEVICES=0'
  -e 'GLOO_SOCKET_IFNAME=enP7s7'
  -e 'LD_PRELOAD=/opt/nccl-ringonly/libnccl.so.2'
  -e 'VLLM_NCCL_SO_PATH=/opt/nccl-ringonly/libnccl.so.2'
  -e "MASTER_ADDR=${MASTER_ADDR}"
  -e "MASTER_PORT=${MASTER_PORT}"
  -e 'NCCL_ALGO=RING'
  -e 'NCCL_CROSS_NIC=1'
  -e 'NCCL_DEBUG=INFO'
  -e 'NCCL_DEBUG_FILE=/nccl-debug/nccl-%h-%p.log'
  # NCCL_IB_GID_INDEX 不设: Tony #38/#40 实证 GID 表 index 漂移, 显式 -1 探测选中邻接不通的 IPv4-mapped GID;
  # GLM 栈同环网 -1 能跑是镜像环境差异, vision lane 以 unset 为准
  -e 'NCCL_IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1'
  -e 'NCCL_IB_TIMEOUT=1000'
  -e 'NCCL_IB_RETRY_CNT=7'
  -e 'NCCL_IB_TOS=46'
  -e 'NCCL_IGNORE_CPU_AFFINITY=1'
  -e 'NCCL_MIN_NCHANNELS=4'
  -e 'NCCL_SET_THREAD_NAME=1'
  -e 'NCCL_NET=IB'
  -e 'NCCL_IB_SUBNET_AWARE_ROUTING=1'
  -e 'NCCL_NET_PLUGIN=none'
  -e 'NCCL_IB_MERGE_NICS=0'
  -e 'NCCL_IB_SUBNET_PREFIX_LEN=24'
  -e 'NCCL_P2P_LEVEL=SYS'
  -e 'NCCL_PROTO=LL,LL128,Simple'
  -e 'NCCL_SKIP_TREE_CONNECT=1'
  -e 'NCCL_TUNER_THRESHOLD=40960'
  -e 'NCCL_MAX_NCHANNELS=4'
# NCCL_IB_PEER_HCA: head(rank0) 按物理环序填两个邻居的 HCA 口, 例:
#   -e 'NCCL_IB_PEER_HCA=1=rocep1s0f1,roceP2p1s0f1;3=rocep1s0f0,roceP2p1s0f0'
  -e 'NCCL_IB_PEER_HCA=<rank1_ifaces>;<rank3_ifaces>'
  -e 'NCCL_SOCKET_IFNAME=enP7s7'
  -e 'NCCL_BUFFSIZE=8388608'
  -e 'NCCL_CUMEM_HOST_ENABLE=0'
  -e "NODE_RANK=${NODE_RANK}"
  -e "VLLM_HOST_IP=${HOST_IP}"
)

mkdir -p "$HOME/.cache/vllm-dspark-v4v" "$HOME/.cache/huggingface" "$HOME/nccl-debug"
# 全新缓存目录 (~/.cache/vllm-dspark-v4v): 天然无陈旧 modelinfos, 免清


docker rm -f "$NAME" 2>/dev/null || true

# boot 窗口无条件 flusher (GB10 NVRM 分配墙纪律; sudo 不可用, 走特权容器)
docker rm -f v4v-flusher 2>/dev/null || true
docker run -d --name v4v-flusher --restart no --privileged \
  --entrypoint bash "$IMG" -lc 'for i in $(seq 90); do sync; echo 3 > /proc/sys/vm/drop_caches; sleep 60; done' 2>/dev/null

docker run -d --name "$NAME" \
  --restart no \
  --network host --ipc=host --privileged --gpus all \
  --cpuset-cpus=1-19 \
  --shm-size=64gb --ulimit memlock=-1 --ulimit stack=67108864 --ulimit nofile=1048576 \
  --memory 112g --memory-swap 112g \
  --log-opt max-size=100m --log-opt max-file=3 \
  --health-cmd "sh /healthcheck.sh" \
  --health-interval 30s --health-timeout 10s --health-retries 5 --health-start-period 900s \
  -v "${HC_SCRIPT:-/home/<user>/v4v-test/hc_v4v.sh}:/healthcheck.sh:ro" \
  -v "$MODEL_DIR:/models:ro" \
  -v /var/tmp/patch3-scheduler.py:/opt/env/lib/python3.12/site-packages/vllm/v1/core/sched/scheduler.py:ro \
  -v /var/tmp/spec-dspark.py:/opt/env/lib/python3.12/site-packages/vllm/v1/spec_decode/dspark.py:ro \
  -v /var/tmp/ds4v_model.py:/opt/env/lib/python3.12/site-packages/vllm/models/deepseek_v4/nvidia/model.py:ro \
  -v /var/tmp/ds4v_vision.py:/opt/env/lib/python3.12/site-packages/vllm/models/deepseek_v4/nvidia/ds4v_vision.py:ro \
  -v /var/tmp/ds4v_mm.py:/opt/env/lib/python3.12/site-packages/vllm/models/deepseek_v4/nvidia/ds4v_mm.py:ro \
  -v /var/tmp/ds4v_registry.py:/opt/env/lib/python3.12/site-packages/vllm/model_executor/models/registry.py:ro \
  -v "$HOME/.cache/vllm-dspark-v4v:/vllm-cache:rw" \
  -v "$HOME/.cache/huggingface:/cache/huggingface:rw" \
  -v /opt/aicad-prod/lib/libncclpin.so:/opt/libncclpin.so:ro \
  -v /opt/nccl-ringonly:/opt/nccl-ringonly:ro \
  -v "$HOME/nccl-debug:/nccl-debug:rw" \
  "${ENV_ARGS[@]}" \
  "$IMG" -lc "$SERVE_CMD"

echo "[i] 容器已启动: ${NAME} (head :8888, id=deepseek-v4-flash-vision-exp)"
echo "[i] 等待就绪 (≤15min cold start): 轮询 docker logs 'Application startup complete'"
if [ "${NO_WAIT:-0}" = "1" ]; then echo "[i] NO_WAIT 模式"; exit 0; fi
for i in $(seq 1 180); do
  if docker logs "$NAME" 2>&1 | grep -q "Application startup complete"; then
    echo "[ok] READY ($((i*10))s)"; exit 0
  fi
  sleep 10
done
echo "[warn] 未就绪; 观察 docker logs ${NAME}" >&2
exit 1
