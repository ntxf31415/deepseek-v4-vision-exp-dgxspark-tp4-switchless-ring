# Pitfalls / 踩坑记录

Everything below was hit and fixed in production on 4× DGX Spark (switchless ring).
全部为 4× DGX Spark 无交换机环网生产实战验证。

## Network / NCCL

1. **Image-baked `VLLM_NCCL_SO_PATH` bypasses LD_PRELOAD.** The runtime image
   bakes a path to stock NCCL 2.30.4; pynccl dlopens that absolute path. Fix:
   explicit `VLLM_NCCL_SO_PATH=/opt/nccl-ringonly/libnccl.so.2`. Symptom if
   missed: `NCCL error: invalid argument` on all four ranks at boot.
2. **Image-baked upstream subnet residue.** `NCCL_IB_ADDR_RANGE=192.168.x.0/24`
   + `ADDR_FAMILY=AF_INET` + `ROCE_VERSION_NUM=2` are baked into the image from
   the upstream author's fabric. On a switchless ring this forces an
   IPv4-mapped GID on a subnet that isn't physically adjacent → QP RTR timeout
   (`ibv_modify_qp failed with 110`). Fix: `unset` them inside SERVE_CMD
   (empty-string overrides are not equivalent to unset).
3. **GID table index drift.** Interface events reshuffle the GID table; a pinned
   `NCCL_IB_GID_INDEX` (even -1 auto-detect) can select a dead GID. Leave it
   entirely unset. Symptom: NCCL `Init COMPLETE` prints, then silent hang /
   `ibv_modify_qp` timeout.
4. **Rank mapping follows the physical ring, not IP order.** Ring is
   N1↔N2↔N4↔N3↔N1 (each edge its own /24). Swapping rank2/rank3 makes PEER_HCA
   per-rank maps point at non-adjacent nodes → QPs to a peer that isn't on that
   wire → RTR timeout that looks like a physical-layer fault.
5. **First-collective deadlock (Alex gotcha).** Occasional boot hang right after
   NCCL init, no errors, memory idle. Full teardown + relaunch fixes it. If it
   reproduces every boot, it's not this — it's a config bug (see above).

## Engine

6. **ncclpin v9 is a 30× tax on this image** (glibc 2.41 vs build env 2.35).
   Loads fine, then each decode step takes ~0.8s. Do not preload it here.
7. **`VLLM_DISABLE_PYNCCL=1` is mandatory.** The image's dual pynccl init
   deadlocks on the first all-reduce (stable, every boot).
8. **Patch 4 (spec-dspark.py) missing = silent half speed.** The DSpark draft's
   shared expert loads uninitialised; acceptance collapses at half decode speed
   with no error. Verify: `grep -c shared_experts .../dspark.py` → 6.
9. **Root-owned modelinfos cache.** Old containers wrote
   `~/.cache/vllm-dspark/modelinfos` as root; a non-root user can't clear it and
   the stale "text-only" model verdict gets reused. Use a fresh cache dir.
10. **Cold-start penalty.** First long generations are slow (JIT/cudagraph
    capture). Warm up with several 500+ token requests before benchmarking.
11. **Thinking budget eats the answer.** With thinking ON, small max_tokens
    leaves content empty (thinking consumes the budget). Downstream must send
    ≥16K. Note: this image writes thinking inline in `content` (no separate
    reasoning_content field), unlike the GLM image.

## Self-heal / ops

12. **monitor rm-echo rebuild storm.** `docker rm -f` inside rebuild makes the
    monitor's `docker wait` return instantly → misread as another crash → rebuild
    loop. Fix: 120s rebuild-window guard ignoring exits during that window.
13. **hang_probe kills cold-booting containers.** After any healthy period, the
    60s probe kills a rebuilding head (health=000 during ~12min boot) → probe↔
    monitor death loop. Fix: container-age guard (≥15min) + liveness guard
    (<5 log lines in 5min).
14. **Monitor is a detached process.** Stopping the head unit does not kill it;
    any manual restart must `pkill -f 'monitor_v4v[_]head'` first (character
    class avoids pkill self-match).
15. **Never reboot with two lane units enabled.** Old lane units left enabled
    will auto-start and fight the active lane for GPUs/ring. Disable retired
    lanes (`systemctl disable`) as part of retirement.
