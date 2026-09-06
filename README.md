# DeepSeek-V4-Flash-Vision-Exp on 4× DGX Spark, TP4, Switchless Ring

Production recipe for serving **deepseek-ai/DeepSeek-V4-Flash-Vision-Exp** (native
vision, NVFP4, 1M context, DSpark speculative decoding) across **4× NVIDIA DGX
Spark (GB10)** connected as a **switchless RoCE ring** (no 400G switch) with a
self-healing systemd stack.

> 中文说明：[README.zh-CN.md](README.zh-CN.md) · Agent quick-start: [AGENTS.md](AGENTS.md)

**Measured on 4× DGX Spark (GB10, sm_121a, switchless ring), gmu 0.82:**

| benchmark (single stream, temp 0) | value |
|---|---|
| decode peak / mean | **107.8 / 80.4** tok/s |
| prefill 8K / 32K / 100K | 1666 / 2486 / 2361 t/s |
| aggregate c1 / c4 / c8 / c12 | 75 / 233 / 222 / 266 tok/s |
| KV pool | **7,877,455 tokens** |
| thinking ON (per-request) | decode parity, c6–c12 aggregate **+45~85%**, 3–7× tokens |
| cold start | ~12 min (autotune cached, ~2s) |
| native image input | verified (red-left / blue-right) |

Full tables incl. thinking ON/OFF: [docs/benchmarks.md](docs/benchmarks.md).

---

> **Sister project:** [GLM-5.3-Flash NVFP4 TP4 switchless-ring](https://github.com/ntxf31415/glm-5.3-flash-nvfp4-4x-dgx-spark-switchless) — the same 4x DGX Spark ring base with a GLM-5.3-Flash recipe (deployment guide + delta checklist). Companion project reusing this ring infrastructure.

## What this is

A deployment + operations layer, not an engine. The recipe combines:

| Component | Origin | License |
|---|---|---|
| Vision port for the DSpark vLLM runtime (ViT + Aligner bind-mounts) | [tonyd2wild/DeepSeek-v4-Flash-Vision-Exp-DSpark-1M-NVFP4-KV-2x-DGX-Spark](https://github.com/tonyd2wild/DeepSeek-v4-Flash-Vision-Exp-DSpark-1M-NVFP4-KV-2x-DGX-Spark) | MIT © 2026 Tony Deangelo |
| Ring-only NCCL 2.30.7 + ring env discipline | [luxingcom/LuZ0.4.5-DeepSeek-v4-Flash-DGXspark-TP4-Ring](https://github.com/luxingcom/LuZ0.4.5-DeepSeek-v4-Flash-DGXspark-TP4-Ring) | Apache-2.0 |
| Runtime image | `ghcr.io/tonyd2wild/vllm-dspark-runtime:mia-raf-pr1-nvfp4-probe-c-keys-concurrency-p2b` | see publisher |
| Model weights | `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp` (Hugging Face) | see model card |

**This repository ships no weights, no images, no NCCL binaries.** It ships the
launcher scripts, systemd units, self-healing monitor, and the operational
knowledge required to run the above on a switchless 4-node ring.

## Hardware & topology

- 4× NVIDIA DGX Spark (GB10, 128 GB unified memory, sm_121a)
- Ring wiring: 4 direct-connect edges, dual-port (f0/f1) per edge, each edge its
  own /24 subnet. Physical ring order is **N1 ↔ N2 ↔ N4 ↔ N3 ↔ N1** — rank
  assignment follows the ring, not IP order (see AGENTS.md, this bit people).
- Bootstrap over 1GbE management LAN; collectives over RoCE ring.
- No switch: ring-only NCCL is mandatory. Stock NCCL cannot establish the tree.

## Quick start

```bash
# 1. Weights (not redistributed here): download deepseek-ai/DeepSeek-V4-Flash-Vision-Exp
#    to each node (or shared storage), e.g. /home/<user>/models/DeepSeek-V4-Flash-Vision-Exp
# 2. Runtime image: docker pull ghcr.io/tonyd2wild/vllm-dspark-runtime:mia-raf-pr1-nvfp4-probe-c-keys-concurrency-p2b
# 3. Generate the 6 patch files on every node (upstream script, not shipped here):
#    clone the Tony repo, run vision-exp/build-ds4v-files.sh <image-tag> /var/tmp
#    plus stage patch3-scheduler.py and spec-dspark.py from recipe/overlay/
# 4. Edit the placeholder variables in scripts/ (${N1_IP}, ${N2_IP}, ${N3_IP}, ${N4_IP},
#    model path, PEER_HCA maps) to match your wiring
# 5. Install systemd units (see systemd/) and start workers first:
for rank in 3 2 1; do ssh node-for-rank-$rank "sudo systemctl start vllm-v4v-worker@$rank"; done
sudo systemctl start vllm-v4v-head.service   # ~12 min cold start
curl http://<head-ip>:8888/health            # -> 200
```

## Key operational decisions (battle-tested)

- `VLLM_NCCL_SO_PATH` must point at the ring-only lib (image bakes a stock-NCCL path)
- **Do not preload ncclpin** on this image (glibc 2.41 → ~30× decode slowdown)
- `VLLM_DISABLE_PYNCCL=1` mandatory (dual-init deadlock on first all-reduce)
- `unset` the image's baked network envs (upstream subnet residue) inside SERVE_CMD
- `NCCL_IB_GID_INDEX` left unset (GID table drift; see AGENTS.md)
- Worker-first launch (3→2→1→0); head serves :8888 directly (no proxy)
- Full pitfall log: [docs/pitfalls.md](docs/pitfalls.md)

## Repository layout

```
scripts/    launchers, self-heal monitor, hang probe, temp watch
systemd/    head/worker units, healthcheck timer
docs/       benchmarks, pitfalls, self-heal drill report
```

## License

Apache-2.0 (see [LICENSE](LICENSE)). Third-party attributions in
[NOTICE](NOTICE). Weights, images and NCCL binaries referenced here carry their
own licenses — read them before use. All IPs, hostnames and credentials are
placeholder-ized.

## Disclaimer

Learning & research reference. Production use at your own risk.
