# Benchmarks / 基准

Method: `bench_full_uuid` (decode 5 content types, temp 0, warm; c1–c12 aggregate
400-token same-prompt; prefill TTFT method 8K/32K/100K, 1 output token).
Hardware: 4× DGX Spark GB10, switchless ring, ring-only NCCL 2.30.7.
口径：bench_full_uuid 三轴（decode 五型 / c1-c12 聚合 / prefill TTFT 法），4× DGX Spark 环网。

## Vision-Exp NVFP4 TP4, gmu 0.82 (production config / 生产配置)

| metric / 指标 | value / 数值 |
|---|---|
| decode peak / mean | **107.8 / 80.4** tok/s |
| c1 / c2 / c4 / c6 / c8 / c12 | 75 / 64 / 233 / 166 / 222 / 266 |
| prefill 8K / 32K / 100K | 1666 / 2486 / 2361 t/s |
| KV pool | 8,416,065 tokens (gmu 0.85) → 7,877,455 (gmu 0.82) |
| cold start | ~12 min (autotune cached: Loaded 30 configs, ~2s) |

vs. upstream switched-fabric reference (Tony TP4, 2026-09-02): decode code 98 /
prose 42 tok/s → ring penalty −10~14% on single-stream, prose at parity.
对上游交换机口径：decode −10~14%，prose 打平。

## thinking ON/OFF (same config, per-request chat_template_kwargs)

| metric | OFF | ON | Δ |
|---|---:|---:|---:|
| decode peak / mean | 107.8 / 80.4 | 108.1 / 81.0 | parity / 持平 |
| c1 | 75 | 79 | +5% |
| c2 | 64 | 140 | +119% |
| c4 | 233 | 224 | −4% |
| c6 | 166 | 307 | +85% |
| c8 | 222 | 369 | +66% |
| c12 | 266 | 386 | +45% |

Mechanism: thinking tokens are highly predictable → DSpark acceptance up.
Trade-off: 3–7× more output tokens; downstream needs max_tokens ≥16K or the
answer is eaten by the thinking budget.
机制：思考 token 高度可预测 → 投机接受率提升。代价：输出 token 3–7 倍；下游
max_tokens 需 ≥16K，否则答案被思考预算吃光。


## prefill-throttle retest (2026-09-08, `--long-prefill-token-threshold 1024`)

Same bench_full_uuid protocol, same engine defaults. Fix targets the
"new session enters → in-flight decode starves" bug (see pitfalls #17):
chunked prefill was consuming the whole per-step token budget, starving
decode for up to ~3.1s per token in the worst observed case.

| metric | baseline (9-05) | LPT 1024 | Δ |
|---|---:|---:|---:|
| decode peak / mean | 107.8 / 80.4 | 107.7 / 82.8 | parity / 持平 |
| c1 | 74.9 | 80.0 | +7% |
| c2 | 63.7 (dip) | **132.0** | **+107%, dip gone** |
| c4 | 233.3 | 227.0 | −3% |
| c6 | 165.8 | **302.2** | **+82%** |
| c8 | 221.8 | **395.3** | **+78%** |
| c12 | 266.0 | **378.2** | **+42%** |
| prefill 8K / 32K / 100K | 1666 / 2486 / 2361 | 2061 / 2163 / 2085 | 8K +24%, 32K −13%, 100K −12% |

Injection test (in-flight 22K decode + new 20K cache-miss session):
ITL peak 3078ms → **666ms**, p99 3044ms → 534ms.

Trade-off: long-prefill absolute throughput −12~13% (finer chunking, more
scheduler steps); a clear net win for multi-session long-context workloads.
Same direction as MiaAI-Lab #27 fix (`long_prefill_token_threshold`, their
value: 1024).
节流复测：并发聚合大涨（c6/c8 +78~82%、c2 凹陷消失），单流持平，长 prefill
吞吐 −12~13% 为分片代价。与 MiaAI-Lab #27 修复同向（同值 1024）。
