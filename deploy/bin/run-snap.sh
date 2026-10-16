#!/usr/bin/env bash
# 一次性打印运行快照（单行 key=value），供本地监控脚本每 2 分钟取一次。
# 之所以做成"一次调用一个快照"，是为了让 SSH 链路抖动不会中断整个监控循环
# —— 长连接式的远端 while 循环一旦断线，监控就整体死掉了。
log=/data/run.log
echo "time=$(date '+%H:%M:%S')" \
     "jobs=$(grep -acE 'Finished jobid' $log)" \
     "steps=$(grep -aoE '[0-9]+ of [0-9]+ steps \([0-9]+%\) done' $log | tail -1 | tr ' ' '_')" \
     "errs=$(grep -acE 'Traceback \(most recent call last\)|^Error in rule|^Error:' $log)" \
     "alive=$(pgrep -f '[s]nakemake --sdm conda' >/dev/null && echo 1 || echo 0)" \
     "busy=$(ps -eo pcpu --sort=-pcpu 2>/dev/null | awk 'NR>1 && $1>20' | wc -l)" \
     "used=$(free -m | awk '/^Mem:/{print $3}')" \
     "avail=$(free -m | awk '/^Mem:/{print $7}')" \
     "big=$(grep -acE 'Prioritize (somatic|altsplicing)' $log)" \
     "load=$(cut -d' ' -f1 /proc/loadavg)"
