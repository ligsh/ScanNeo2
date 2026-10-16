#!/bin/bash
# 从 OSS 流式抽取子集：每个文件取前 1/DIV 的压缩字节 → 解压有效前缀 →
# 按记录数严格截断（保证 R1/R2 等长）→ 重新压缩成合法 .gz
# 用法: make-subset.sh [DIV]   （DIV 默认 10）
#
# 注意：这里刻意不用 set -e / pipefail —— 被截断的 gzip 流解压到结尾时必然报错，
# 那是预期行为。改为在每步之后显式校验产物，不合格就退出。
set -u
SRC="myoss:ligsh-bucket-01/ScanNeo2/inputs/26N0108/20261008"
DST="/data/inputs/P26N0108/subset"
DIV="${1:-10}"
RCLONE="rclone --config /data/etc/rclone.conf"
LIBS="DN26N0108SLZAA26 DN26N0108XYZAA26 RN26N0108SLZAA09"
mkdir -p "$DST"

fail() { echo "[$(date +%H:%M:%S)] ✗ $*"; exit 1; }

for lib in $LIBS; do
    mkdir -p "$DST/$lib"
    n=""
    for pair in R1 R2; do
        f=$($RCLONE lsf "$SRC/$lib/" 2>/dev/null | grep "_${pair}_001.fastq.gz" || true)
        [ -n "$f" ] || fail "$lib 的 $pair 文件在 OSS 上没找到（检查 remote 名与路径）"
        size=$($RCLONE lsl "$SRC/$lib/$f" 2>/dev/null | awk '{print $1}')
        case "$size" in ''|*[!0-9]*) fail "$lib/$f 取不到大小（size='$size'）" ;; esac
        prefix=$(( size / DIV ))
        out="$DST/$lib/$f"

        if [ "$pair" = "R1" ]; then
            n=$($RCLONE cat "$SRC/$lib/$f" --count "$prefix" 2>/dev/null | gzip -dc 2>/dev/null | wc -l | tr -d ' ')
            n=$(( n / 4 ))
            [ "$n" -gt 0 ] || fail "$lib/$f 前缀解压得到 0 条 read"
            echo "[$(date +%H:%M:%S)] $lib  前缀 $n 条 read（R1/R2 都按这个数截断）"
        fi

        $RCLONE cat "$SRC/$lib/$f" --count "$prefix" 2>/dev/null \
          | gzip -dc 2>/dev/null | head -n $(( n * 4 )) | gzip -1 > "$out"
        got=$(gzip -dc "$out" 2>/dev/null | wc -l | tr -d ' '); got=$(( got / 4 ))
        gzip -t "$out" 2>/dev/null || fail "$out 不是完整的 gz"
        [ "$got" -eq "$n" ] || fail "$out 记录数 $got ≠ 预期 $n"
        echo "[$(date +%H:%M:%S)]   ✓ $(basename "$out")  $got 条  $(du -h "$out" | cut -f1)"
    done
done

echo "[$(date +%H:%M:%S)] 全部完成，最终校验："
for lib in $LIBS; do
    for pair in R1 R2; do
        f=$(ls "$DST/$lib/" | grep "_${pair}_001" | head -1)
        n=$(gzip -dc "$DST/$lib/$f" 2>/dev/null | wc -l | tr -d ' '); n=$(( n / 4 ))
        printf "   %-56s %9s 条\n" "$lib/$f" "$n"
    done
done
echo "[$(date +%H:%M:%S)] 子集合计 $(du -sh "$DST" | cut -f1)"
