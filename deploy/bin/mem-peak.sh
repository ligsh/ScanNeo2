#!/usr/bin/env bash
# 每 10 秒记录一次内存/CPU 快照到日志，用于复盘每条规则实际的资源占用。
#
# 内存区块：全局 used/avail + 按 RSS 排序的前 3 个进程（行尾 G）
# CPU 区块：按平均 CPU 排序的前 4 个进程（行尾 c），格式
#               <核数>c <PID> <comm> <命令行头 ... 命令行尾>
#
# 三个刻意的设计，每一个都对应一个踩过的坑：
#  1. 记 PID。ps 的 %CPU = CPU时间/存活时间，存活几十毫秒的短命进程（如
#     SplAdder 派生的 cbc）会算出 40 核这种物理上不可能的值。只有按 PID
#     统计"出现在几个采样点"，才能把它们识别出来；按进程名统计识别不了
#     ——68 个各不相同的 cbc 会被当成同一个进程出现 68 次。
#  2. 命令行头尾都记。java 的工具名在命令行末尾，只记头部会把 Mutect2 /
#     HaplotypeCaller / VQSR 混成一个签名；而尾部的输出路径里含 mutect2/、
#     htcaller/ 这类字段，是"进程→规则"最可靠的归属线索。
#  3. 不在这里过滤，过滤留给汇总阶段做 —— 原始数据保持完整，判断标准
#     可以事后调整。
#
# 用法：mem-peak.sh [日志路径]     默认 /data/mem-peak.log
LOG="${1:-/data/mem-peak.log}"

# 命令行过长时保留头 60 字符和尾 70 字符（中间用 ... 连接）
short() {
  awk -v a="$1" 'BEGIN{
    n = length(a)
    if (n <= 95) print a
    else print substr(a,1,60) " ... " substr(a, n-70)
  }'
}

while true; do
  {
    date '+=== %m-%d %H:%M:%S'
    free -m | awk '/^Mem:/{printf "used=%sM avail=%sM\n", $3, $7}'

    ps -eo rss=,args= --sort=-rss 2>/dev/null | head -3 | while read -r rss args; do
      awk -v r="$rss" -v a="$(short "$args")" 'BEGIN{printf "  %6.2fG  %s\n", r/1048576, a}'
    done

    ps -eo pcpu=,pid=,comm=,args= --sort=-pcpu 2>/dev/null | head -4 | while read -r pc pid comm args; do
      awk -v p="$pc" -v i="$pid" -v c="$comm" -v a="$(short "$args")" \
        'BEGIN{printf "  %6.2fc %8s  %-16s %s\n", p/100, i, c, a}'
    done
  } >> "$LOG"
  sleep 10
done
