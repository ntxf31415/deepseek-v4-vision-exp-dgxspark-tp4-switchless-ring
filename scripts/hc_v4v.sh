#!/bin/sh
# 容器内健康检查: 本 rank 的 vLLM 引擎进程存活即健康。
#   - head(rank0)  = VLLM::EngineCore + VLLM::Worker_TP0
#   - worker(rankN)= VLLM::Worker_TP{n}   (--headless, 无 /health 端点)
# 匹配前缀 "VLLM::" 统一覆盖 head/worker; 用 chr 拼接构造, 避免探针自身 cmdline 含该串被误匹配。
/opt/env/bin/python -c 'import os,sys
T = "".join(chr(c) for c in (86,76,76,77,58,58))   # "VLLM::"
try:
    for p in os.listdir("/proc"):
        if p.isdigit():
            d = open("/proc/"+p+"/cmdline","rb").read().decode("utf-8","ignore")
            if T in d:
                sys.exit(0)
except Exception:
    pass
sys.exit(1)'
