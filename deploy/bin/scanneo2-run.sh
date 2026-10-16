#!/bin/bash
# ScanNeo2 运行入口。用法: /data/bin/scanneo2-run.sh [snakemake 参数...]
#   /data/bin/scanneo2-run.sh -c 32 --until get_genome    # 只跑到某步
#   /data/bin/scanneo2-run.sh -c 32                       # 全流程
set -euo pipefail
[ -d /data/ScanNeo2 ] || { echo "错误: /data 未挂载或无仓库"; exit 1; }
cd /data/ScanNeo2
# fetch_resource.sh 靠这两个变量给 OSS 请求签名；没有它们下载会 403
set -a; . /data/etc/oss.env; set +a
export PATH=/data/miniforge3/envs/scanneo2/bin:/data/miniforge3/bin:$PATH
exec snakemake --sdm conda --conda-frontend mamba "$@"
