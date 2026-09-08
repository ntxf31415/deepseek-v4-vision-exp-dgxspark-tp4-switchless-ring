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
    (<5 log lines in 5min). Since 2026-09-08 a **boot-blindspot branch** was added:
    if the head has been up ≥30min, never became healthy this boot, and is
    log-quiet, the probe kills to let self-heal take over. This closes the 09-07
    machine-reboot gap (STATE stale after reboot → probe never fired). It only
    fires at age ≥30min (2× cold-start) and log-quiet, so it won't kill a normal
    long silent boot (autotune/JIT retune).
14. **Monitor is a detached process.** Stopping the head unit does not kill it;
    any manual restart must `pkill -f 'monitor_v4v[_]head'` first (character
    class avoids pkill self-match).
15. **Never reboot with two lane units enabled.** Old lane units left enabled
    will auto-start and fight the active lane for GPUs/ring. Disable retired
    lanes (`systemctl disable`) as part of retirement.
16. **`pgrep` healthcheck fails on this minimal image → containers always
    `unhealthy`.** The image has no `pgrep`/`ps`, so
    `--health-cmd "pgrep -f VLLM::EngineCore ..."` exits 1 every time (false
    negative; the engine is fine). Fix: mount `scripts/hc_v4v.sh` and use
    `--health-cmd "sh /healthcheck.sh"` — it scans `/proc/*/cmdline` for a
    `VLLM::` prefix. Two gotchas: (a) head(rank0) runs `VLLM::EngineCore` +
    `VLLM::Worker_TP0` but headless workers run only `VLLM::Worker_TP{n}` and
    have no `/health` endpoint, so match the `VLLM::` prefix, not one specific
    name; (b) build the target string via `chr()` concatenation or the probe's
    own `python -c` cmdline matches itself and reports healthy even when the
    engine is dead.
17. **Chunked prefill starves in-flight decode ("new session enters → decode
    drops to single digits").** With `long_prefill_token_threshold=0` (default)
    and chunked prefill, an entering session's prefill consumes the whole
    per-step token budget every step; in-flight sessions get zero decode budget
    for the entire prefill duration. Measured on our ring: worst inter-token
    latency 3078ms (≈0.33 tok/s instantaneous) while a 20K cache-miss prompt
    prefilled. Same root cause as MiaAI-Lab
    deepseek-v4-flash-dspark-2x-dgx-spark#27 (their v1 scheduler also never
    reads `max_num_partial_prefills`). Fix: `--long-prefill-token-threshold
    1024` (upstream uses the same value). ITL peak 3078→666ms; concurrency
    benchmark c6/c8 +78~82% (see benchmarks.md retest).
18. **"decode collapses at long context" is usually a measurement artifact,
    not a kernel bug.** Wall-time/out-token (or the engine's `Avg generation
    throughput` line) amortizes TTFT into "decode speed" — a 22K-context
    request with 7–9s TTFT reads as "7 tok/s" while streaming per-token
    measurement shows 40+ tok/s. Before hunting kernel bugs (e.g. flashinfer
    autotuner issues), always re-measure with streamed token timestamps,
    both single-stream and with a concurrent prefill injected.
并发 prefill 饥饿与「wall/out 口径假象」：新会话进入掉速先查调度节流参数，
别急着归因 kernel；任何 decode 崩塌结论必须流式逐 token + 并发注入复核。
19. **Serving unauthenticated on 0.0.0.0.** vLLM's `--api-key` is opt-in:
    without it every `/v1/*` path answers with 200 for any caller. On a LAN
    any device can consume or abuse the engine. Fix: `--api-key <value>`
    (downstreams must then send the key; `/health` and `/metrics` stay
    unauthenticated — probes/dashboards keep working). The default value in
    these scripts (`Dgxdual`) is a local convention — change it for your
    network and sync every consumer (portal, dashboards, hermes agents).
`--api-key` 是 opt-in：不加则 /v1/* 对任何调用者 200。务必设置，且下游同步换 key。

20. **No health/self-heal alerting = the 09-07 blindspot.** With only the hang
    probe and auto-rebuild, a crash where `/health` stays 200 until the moment of
    the crash (then the probe's STATE is stale) can go unnoticed — nobody is told
    the ring is down or looping. Fix (2026-09-08): `v4v_alert.sh` +
    `vllm-v4v-alert.timer` aggregate four signals (Docker-health FailingStreak≥3,
    hang-probe kill, monitor rebuild, temp ALARM) into a persistent status file
    and optionally POST a webhook (`V4V_ALERT_WEBHOOK`). No webhook configured =
    status/log only; `systemctl disable --now vllm-v4v-alert.timer` reverts.
20. **nvfp4 KV decode dispatch misses the fp8 fast path.** Older trees route
    `nvfp4_ds_mla` KV through `_forward_bf16_kv` because
    `use_fp8_cache = self.kv_cache_dtype == "fp8_ds_mla"` omits nvfp4. On
    some stacks (Anemll 0.1.1) this is a 16x long-context regression
    (MiaAI #22); on the 0.21.1rc1 dev line we measured no speed difference
    (dispatch is still wrong — fix it). Fix: `in ("fp8_ds_mla",
    "nvfp4_ds_mla")` (Tony 1d57054b, same one-liner). Ship as a bind-mount
    patch like any other vLLM source patch.
nvfp4 decode 分发漏掉 fp8 快路径：0.21.1rc1 dev 线实测无性能差异但分发语义错误，
照 Tony 1d57054b 一行修复，作为挂载补丁分发。
