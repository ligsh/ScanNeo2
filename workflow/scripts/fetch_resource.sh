#!/bin/bash
#
# 从资源镜像取一个文件。命中 OSS 且环境里有凭据时，用 curl 内建的 SigV4 签名
# （私有镜像）；否则按普通 HTTP 下载（公共镜像）——对使用公共镜像的人完全透明。
#
# 用法: bash workflow/scripts/fetch_resource.sh <url> <输出路径|->
#       输出路径传 - 表示写到标准输出，供 `| tar xz` 这类管道使用。
#
# 凭据从环境变量读：OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET
# （两者都非空才签名；region 默认从主机名解析，可用 OSS_REGION 覆盖。）
#
# 与它替换掉的裸 curl 相比：重试次数统一为 5，且写文件时带 -C -（断点续传）。

set -euo pipefail

url="${1:?用法: fetch_resource.sh <url> <输出路径|->}"
out="${2:?用法: fetch_resource.sh <url> <输出路径|->}"

args=(--fail -L --retry 5 --retry-all-errors)
# 只有写文件时才能续传；写标准输出时 -C - 无意义
if [[ "$out" != "-" ]]; then
    args+=(-C -)
fi

host="${url#*://}"
host="${host%%/*}"

if [[ "$host" == *.aliyuncs.com && -n "${OSS_ACCESS_KEY_ID:-}" && -n "${OSS_ACCESS_KEY_SECRET:-}" ]]; then
    # 例：bucket.oss-cn-beijing-internal.aliyuncs.com → cn-beijing
    region="${OSS_REGION:-$(printf '%s' "$host" | sed -nE 's/^.*oss-(.*)\.aliyuncs\.com$/\1/p')}"
    region="${region%-internal}"
    if [[ -z "$region" ]]; then
        echo "错误: 无法从主机名 ${host} 解析 OSS region，请设置 OSS_REGION" >&2
        exit 1
    fi
    args+=(--aws-sigv4 "aws:amz:${region}:s3" --user "${OSS_ACCESS_KEY_ID}:${OSS_ACCESS_KEY_SECRET}")
fi

exec curl "${args[@]}" -o "$out" "$url"
