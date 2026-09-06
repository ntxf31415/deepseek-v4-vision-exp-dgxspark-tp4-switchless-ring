# DeepSeek-V4-Flash-Vision-Exp 在 4× DGX Spark 无交换机环网上的 TP4 部署

将 **deepseek-ai/DeepSeek-V4-Flash-Vision-Exp**（原生视觉、NVFP4、1M 上下文、DSpark 投机解码）以 **4× NVIDIA DGX Spark（GB10）无交换机 RoCE 环网**（免 400G 交换机）形态部署为生产服务的配方，含自愈链（systemd + monitor + 挂起探针）。

> English: [README.md](README.md) · Agent 快速上手指南：[AGENTS.md](AGENTS.md)

**实测（4× DGX Spark / GB10 / sm_121a，无交换机环网，gmu 0.82）：**

| 基准（单流，temp 0） | 数值 |
|---|---|
| decode 峰 / 均 | **107.8 / 80.4** tok/s |
| prefill 8K / 32K / 100K | 1666 / 2486 / 2361 t/s |
| 聚合 c1 / c4 / c8 / c12 | 75 / 233 / 222 / 266 tok/s |
| KV 池 | **7,877,455 tokens** |
| thinking ON（按请求开启） | decode 持平，c6–c12 聚合 **+45~85%**，输出 token 3–7 倍 |
| 冷启动 | ~12 分钟（autotune 缓存命中后 ~2s） |
| 原生图片输入 | 验证通过（红左蓝右） |

完整表格（含 thinking ON/OFF 对比）：[docs/benchmarks.md](docs/benchmarks.md)。

---

## 这是什么

一个**部署与运维层**，不是引擎。配方组成：

| 组件 | 来源 | 许可 |
|---|---|---|
| DSpark vLLM 运行时的视觉移植（ViT + Aligner bind-mount） | [tonyd2wild/DeepSeek-v4-Flash-Vision-Exp-DSpark-1M-NVFP4-KV-2x-DGX-Spark](https://github.com/tonyd2wild/DeepSeek-v4-Flash-Vision-Exp-DSpark-1M-NVFP4-KV-2x-DGX-Spark) | MIT © 2026 Tony Deangelo |
| ring-only NCCL 2.30.7 + 环网环境纪律 | [luxingcom/LuZ0.4.5-DeepSeek-v4-Flash-DGXspark-TP4-Ring](https://github.com/luxingcom/LuZ0.4.5-DeepSeek-v4-Flash-DGXspark-TP4-Ring) | Apache-2.0 |
| 运行时镜像 | `ghcr.io/tonyd2wild/vllm-dspark-runtime:mia-raf-pr1-nvfp4-probe-c-keys-concurrency-p2b` | 以发布页为准 |
| 模型权重 | `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp`（Hugging Face） | 以模型卡为准 |

**本仓库不分发权重、镜像、NCCL 二进制。** 只分发启动脚本、systemd 单元、自愈 monitor 与运维知识。

## 硬件与拓扑

- 4× NVIDIA DGX Spark（GB10，128 GB 统一内存，sm_121a）
- 环网接线：4 条直连边、每条边双口（f0/f1）、每边独立 /24 子网。**物理环序为 N1 ↔ N2 ↔ N4 ↔ N3 ↔ N1**——rank 按环序分配，不是按 IP 尾号（这一点坑过很多人，见 AGENTS.md）
- bootstrap 走 1GbE 管理网；集合通信走 RoCE 环
- 无交换机：必须 ring-only NCCL。官方 NCCL 无法建树

## 快速开始

```bash
# 1. 权重（本仓库不随附）：下载 deepseek-ai/DeepSeek-V4-Flash-Vision-Exp
#    到各节点（或共享存储），如 /home/<user>/models/DeepSeek-V4-Flash-Vision-Exp
# 2. 运行时镜像：docker pull ghcr.io/tonyd2wild/vllm-dspark-runtime:mia-raf-pr1-nvfp4-probe-c-keys-concurrency-p2b
# 3. 各节点生成 6 个补丁文件（用上游脚本，本仓库不随附）：
#    clone Tony 仓库，运行 vision-exp/build-ds4v-files.sh <image-tag> /var/tmp
#    再从 recipe/overlay/ 放置 patch3-scheduler.py 与 spec-dspark.py
# 4. 编辑 scripts/ 内的占位变量（${N1_IP} 等四个节点 IP、模型路径、PEER_HCA 映射）
#    使其匹配你的接线
# 5. 安装 systemd 单元（见 systemd/），worker 先起：
for rank in 3 2 1; do ssh rank-$rank 对应节点 "sudo systemctl start vllm-v4v-worker@$rank"; done
sudo systemctl start vllm-v4v-head.service   # 冷启动约 12 分钟
curl http://<head-ip>:8888/health            # -> 200
```

## 关键运维决策（实战验证）

- `VLLM_NCCL_SO_PATH` 必须指向 ring-only 库（镜像烘焙的路径指向官方 NCCL）
- **不要预加载 ncclpin**（该镜像 glibc 2.41 下 decode 慢 ~30 倍）
- `VLLM_DISABLE_PYNCCL=1` 必带（首次 all-reduce 双初始化死锁）
- SERVE_CMD 内 `unset` 镜像烘焙的上游网络环境残留
- `NCCL_IB_GID_INDEX` 不设置（GID 表漂移；详见 AGENTS.md）
- worker-first 启动（3→2→1→0）；head 直连 :8888（无代理）
- 全部踩坑记录：[docs/pitfalls.md](docs/pitfalls.md)

## 仓库结构

```
scripts/    启动器、自愈 monitor、挂起探针、温度哨兵
systemd/    head/worker 单元、healthcheck timer
docs/       基准、踩坑、自愈演练报告
```

## 许可

Apache-2.0（见 [LICENSE](LICENSE)）。第三方声明见 [NOTICE](NOTICE)。本仓库引用的权重、镜像、NCCL 二进制各有独立许可，使用前请阅读。所有 IP、主机名、凭据均已占位符化。

## 免责

仅供学习研究参考，生产使用风险自负。
