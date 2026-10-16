#!/bin/bash
#
# 收工：把结果同步到 OSS 并校验，然后打印"云侧收工清单"。
#
# 为什么需要它：结果只留在数据盘上是危险的 —— 数据盘要被释放，唯一的副本就只剩快照。
# 这个脚本把结果同步出去并逐个文件核对大小，同步不通过就不让你往下走。
#
# 它做不到的：打快照、卸载/释放云盘、停机 —— 那些要调阿里云 API（需要 ECS 权限的 AK），
# 所以它最后会打印云侧步骤与顺序，你在控制台照着做。
#
# 用法: /data/bin/scanneo2-down.sh [批次名] [--dry-run]
#   批次名默认取当前时间戳。上传目标: myoss:ligsh-bucket-01/ScanNeo2/results/<批次名>/
set -uo pipefail

BATCH=""; DRY=0
for a in "$@"; do
    case "$a" in
    --dry-run | -n) DRY=1 ;;
    -h | --help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知参数: $a" >&2; exit 2 ;;
    *) BATCH="$a" ;;
    esac
done
BATCH="${BATCH:-$(date +%Y%m%d-%H%M)}"

R="rclone --config /data/etc/rclone.conf"
DEST="myoss:ligsh-bucket-01/ScanNeo2/results/${BATCH}"
SRC=/data/ScanNeo2

echo "批次名: $BATCH    目标: $DEST"
[ "$DRY" -eq 1 ] && echo "（--dry-run：只演示，不实际上传）"

echo
echo "[1/3] 确认没有任务还在跑"
if pgrep -f "[s]nakemake --sdm conda" >/dev/null 2>&1; then
    echo "  ✗ 还有 snakemake 在运行。等它结束（或先停掉），否则会同步到一半的状态。"
    exit 1
fi
echo "  ✓ 没有运行中的任务"

echo
echo "[2/3] 同步 results/ logs/ config/ 到 OSS"
for d in results logs config; do
    [ -e "$SRC/$d" ] || { echo "  - $d 不存在，跳过"; continue; }
    if [ "$DRY" -eq 1 ]; then
        echo "  - 会同步 $d （$(du -sh "$SRC/$d" 2>/dev/null | awk '{print $1}')）"
    else
        out=$($R copy "$SRC/$d" "$DEST/$d/" --stats-one-line --stats 60s 2>&1) && rc=0 || rc=1
        printf '%s\n' "$out" | tail -1 | sed 's/^/    /'
        if [ "$rc" -eq 0 ]; then echo "  - $d 已同步"; else echo "  ✗ $d 同步失败"; RC=1; fi
    fi
done

echo
echo "[3/3] 逐个文件核对大小"
RC=0
if [ "$DRY" -eq 1 ]; then
    echo "  （dry-run 跳过核对）"
else
    for d in results logs config; do
        [ -e "$SRC/$d" ] || continue
        out=$($R check "$SRC/$d" "$DEST/$d/" --size-only --one-way 2>&1) && rc=0 || rc=1
        printf '%s\n' "$out" | tail -3 | sed 's/^/    /'
        if [ "$rc" -eq 0 ]; then echo "  ✓ $d 与 OSS 一致"; else echo "  ✗ $d 核对不通过"; RC=1; fi
    done
fi

echo
echo "════════════════════════════════════════════════"
if [ "$RC" -ne 0 ]; then
    echo "结果同步或核对失败 —— 先解决，不要往下做快照/释放。"
    exit 1
fi
cat <<'CHECKLIST'
接下来的云侧操作（顺序不能反，"确认快照可用"是分界线）：

  1. 在本机执行:  sudo umount /data
  2. 控制台:      给数据盘打快照
  3. 控制台:      等快照状态变成"可用" —— 没到这一步不要往下
  4. 控制台:      卸载数据盘（变为"待挂载"）
  5. 控制台:      释放数据盘
  6. 控制台:      停机实例（不是释放！系统盘要留着，否则下次要重装软件）

下次开工:
  启动实例 → 用快照创建数据盘（同可用区、容量≥快照）→ 挂载到实例
  → sudo mount -a → /data/bin/scanneo2-up.sh → /data/bin/scanneo2-run.sh -c <核数>

详细步骤见 OSS 上的 ScanNeo2/deploy/RUNBOOK.md（机器 umount 后就读不到本地那份了）。
CHECKLIST
