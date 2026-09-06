# AGENTS.md — Deployment guide for AI agents

You are helping deploy/operate DeepSeek-V4-Flash-Vision-Exp on 4× DGX Spark
(switchless ring, TP4). Read this before touching anything.

## Golden rules (violating these breaks the cluster)

1. **Rank order follows the physical ring, not IP order.** Ring: `N1 ↔ N2 ↔ N4 ↔ N3 ↔ N1`.
   N1=rank0(head), N2=rank1, N4=rank2, N3=rank3. Getting rank2/rank3 swapped is the
   #1 failure mode (NCCL builds QPs to a node that isn't physically adjacent → RTR timeout).
2. **`NCCL_IB_GID_INDEX` stays unset.** GID table indexes drift on interface events.
   Pinning it (even `-1`) can select an IPv4-mapped GID on the wrong subnet → silent
   handshake hang after NCCL init. Leave it absent.
3. **Do not preload ncclpin** on the probe-c runtime image (glibc 2.41). It loads fine
   but costs ~30× decode speed (verified: 241s → 7.3s on the same prompt).
4. **`VLLM_DISABLE_PYNCCL=1` is mandatory.** Without it, the image's dual pynccl init
   deadlocks on the first all-reduce (stable repro, not flaky).
5. **The image bakes upstream network residue.** Inside SERVE_CMD, `unset`
   `NCCL_IB_ADDR_RANGE NCCL_IB_ADDR_FAMILY NCCL_IB_ROCE_VERSION_NUM NCCL_P2P_DISABLE
   NCCL_IB_DISABLE NCCL_NVLS_ENABLE NCCL_CUMEM_ENABLE` (and anything else baked).
6. **`VLLM_NCCL_SO_PATH=/opt/nccl-ringonly/libnccl.so.2`** — the image bakes a path to
   stock NCCL 2.30.4; dlopen ignores LD_PRELOAD. Check `docker logs | grep 'using nccl'`
   shows 2.30.7 after boot.
7. **Launch order is worker-first: 3 → 2 → 1 → 0(head).** Opposite of the LuZ stack's
   head-first. Monitor rebuilds use the same order.
8. **Engine serves :8888 directly.** No proxy in front. Cold start is ~12 min
   (autotune + graphs). JIT retuning after any topology change can take longer —
   do not treat a long silent boot as a hang unless NCCL debug shows errors.
9. **Do not run two engines at once.** Every lane (GLM, LuZ, vision) is 4-machine
   exclusive. systemd Conflicts guard units, but stray containers/manual launches
   will fight for GPUs and the ring.
10. **Weights, images, NCCL binaries are not in this repo.** Never commit them. The
    6 patch files (`patch3-scheduler.py`, `spec-dspark.py`, `ds4v_*.py`) are generated
    per-node from the runtime image via the upstream `build-ds4v-files.sh` — generated
    files are image-specific; don't copy them between image versions.

## Preflight (every node)

```bash
docker image inspect ghcr.io/tonyd2wild/vllm-dspark-runtime:mia-raf-pr1-nvfp4-probe-c-keys-concurrency-p2b
ls /var/tmp/{patch3-scheduler,spec-dspark,ds4v_model,ds4v_vision,ds4v_mm,ds4v_registry}.py  # 6 files
ls <MODEL_DIR>/model-00001-of-00048.safetensors
# GID sanity (LuZ gid_preflight): each HCA's GID table must not be all-zero
cat /sys/class/infiniband/rocep1s0f0/ports/1/gids/0
# Ring NICs UP + MTU 9000 both ends
ip -br link | grep -E 'enp1s|enP2p'
```

## Boot (cold)

```bash
# per worker node, ring order: rank3 first
NODE_RANK=3 bash start_v4v_worker.sh   # on N3
NODE_RANK=2 bash start_v4v_worker.sh   # on N4
NODE_RANK=1 bash start_v4v_worker.sh   # on N2
bash start_v4v_head.sh                 # on N1, serves :8888
```

## Verify

```bash
curl -s http://N1:8888/health                                   # 200
docker exec vllm-v4v-tp4-rank0 grep -c shared_experts \
  /opt/env/lib/python3.12/site-packages/vllm/v1/spec_decode/dspark.py   # must be 6
docker logs vllm-v4v-tp4-rank0 | grep 'using nccl'              # 2.30.7
docker logs vllm-v4v-tp4-rank0 | grep 'GPU KV cache size'       # ~7.9M tokens @ gmu 0.82
# warm up before benchmarking (cold-start penalty): several 500+ token generations
```

## Self-heal stack (how it recovers)

- `monitor_v4v_head.sh` (spawned by head unit ExecStartPost, detached): follows the
  rank0 container with `docker wait`; on exit → forensics → worker-first full rebuild.
  120s rebuild-window guard ignores rm-echo exits; ≥3 rebuilds/30min → 30min cooldown.
- `hang_probe_v4v.sh` (60s timer): kills rank0 only if (a) previously healthy ≤30min,
  (b) container age ≥15min (cold-boot protection), (c) <5 log lines in last 5min
  (liveness guard). Without (b) the probe kills rebuilding containers → probe-monitor
  death loop.
- **Before any manual restart**: `pkill -f 'monitor_v4v[_]head'` (the monitor is a
  detached process — stopping the unit does not kill it; leaving it alive makes it
  fight your manual rebuild). The head unit restart respawns it.
- `pkill -f` self-matches: always use the `[_]` character-class form.

## Image quirks (verified, do not "fix")

- entrypoint is `bash` — `docker run <img> -lc '...'` works (unlike the GLM image).
- Thinking is off by default (`--default-chat-template-kwargs '{"thinking":false}'`).
  Per-request `chat_template_kwargs: {"thinking": true}` enables it; thinking ON
  raises aggregate throughput ~45-119% (speculative acceptance) at 3-7× token cost.
  Downstream must send max_tokens ≥16K when thinking is on, or the answer is eaten.
- The 6 bind-mounts must land on **every** node; a missing Patch 4 mounts silently
  at half decode speed.
- Memory: 112g container cap; gmu controls KV pool only. Runtime headroom at gmu 0.82
  is ~12G/node — the risk is concurrency peaks (max-num-seqs 64), not steady state.

## Ports / naming

| thing | value |
|---|---|
| engine API | :8888 (no key on engine; LAN only) |
| master port | 25998 (25999 was the GLM lane's) |
| containers | `vllm-v4v-tp4-rank{0,1,2,3}` on N1/N2/N4/N3 |
| units | `vllm-v4v-head.service`, `vllm-v4v-worker@{1,2,3}.service`, `vllm-v4v-healthcheck.timer` |
| cache dir | `~/.cache/vllm-dspark-v4v` (fresh dir; the old one is root-owned) |

## Docs

- Full pitfall log: docs/pitfalls.md · Benchmarks: docs/benchmarks.md
- Upstream: tonyd2wild/DeepSeek-v4-Flash-Vision-Exp-DSpark-1M-NVFP4-KV-2x-DGX-Spark
  (MIT), luxingcom/LuZ0.4.5-DeepSeek-v4-Flash-DGXspark-TP4-Ring (Apache-2.0)
