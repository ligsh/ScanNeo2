#!/usr/bin/env bash
# 从 mem-peak.log 汇总峰值核数与峰值内存，用于判断 profile 里 threads / mem_mb
# 的声明是否虚高。日志混有三代采样格式（采样器迭代过三次），全部识别：
#   v1/v2（无 PID）: " 12.34c  <命令行头 ... 尾>"  /  " 12.34G  <路径>"
#   v3（带 PID）   : " 12.34c   <PID>  <comm>  <命令行头 ... 尾>"
#
# 三条度量规则，各对应一个踩过的坑：
#  1. 带 PID 的行：只采信在 >=3 个采样点（>=30 秒）出现过的进程。ps 的 %CPU =
#     CPU时间/存活时间，存活几十毫秒的短命进程（如 SplAdder 派生的 cbc）会
#     算出 40 核这种物理上不可能的值。
#  2. 有 PID 的进程取"最后一次观测值"而非最大值。因为 %CPU 是生命周期均值，
#     进程刚启动时天然偏高——取最大值仍然高估，取最后观测值（观测窗口最长）
#     才接近真实。旧格式无 PID，只能取最大值，靠"不超过机器核数"兜底。
#  3. 同一规则的多个 PID 归并成一行，取其中最大者。
#
# 用法：summarize-peaks.sh [日志路径] [机器核数]
LOG="${1:-/data/mem-peak.log}"
NCPU="${2:-$(nproc)}"

AWK='
function hint(s) {
  if (s ~ /mutect2\//)      return "detect_short_indels_m2 (Mutect2)"
  if (s ~ /htcaller\//)     return "detect_variants_htc_* (HaplotypeCaller)"
  if (s ~ /spladder/)       return "spladder"
  if (s ~ /scanexitron/)    return "scanexitron"
  if (s ~ /bwa_index/)      return "bwa_index"
  if (s ~ /star_index/)     return "star_index"
  if (s ~ /markdup/)        return "rnaseq_postproc_markdup"
  if (s ~ /compile\.py/)    return "prioritize_source (compile.py)"
  if (s ~ /prioritization/) return "prioritize_source"
  if (s ~ /vep/)            return "annotate_variants (VEP)"
  if (s ~ /recal/)          return "recalibrate_*"
  if (s ~ /arriba/)         return "arriba"
  if (s ~ /fastp/)          return "preproc (fastp)"
  return ""
}

/^  *[0-9]+\.[0-9]+c / {
  line=$0; sub(/^ +/,"",line); c=line+0
  rest=line; sub(/^[0-9.]+c +/,"",rest)
  pid=""; comm=""; ctx=rest
  if (rest ~ /^[0-9]+ +/) {
    split(rest,t," "); pid=t[1]; comm=t[2]
    ctx=rest; sub(/^[0-9]+ +/,"",ctx); sub(/^[^ ]+ +/,"",ctx)
  } else {
    split(rest,t," "); comm=t[1]
  }
  key = (pid=="" ? comm : comm "|" pid)
  c_n[key]++; c_pid[key]=pid; c_comm[key]=comm
  c_last[key]=c+0
  if (c+0 > c_max[key]) c_max[key]=c+0
  if (hint(ctx) != "") c_rule[key]=hint(ctx)
  next
}

/^  *[0-9]+\.[0-9]+G/ {
  line=$0; sub(/^ +/,"",line); g=line+0
  rest=line; sub(/^[0-9.]+G +/,"",rest)
  h=hint(rest)
  if (h=="") { b=rest; sub(/ .*/,"",b); n=split(b,p,"/"); h=p[n] }
  if (g+0 > g_max[h]) g_max[h]=g+0
  g_n[h]++
  next
}

END {
  for (k in c_max) {
    pid=c_pid[k]; n=c_n[k]
    if (pid != "" && n < 3) continue
    if (pid == "" && c_max[k] > ncpu) continue
    r = (c_rule[k] != "" ? c_rule[k] : c_comm[k])
    val = (pid=="" ? c_max[k] : c_last[k])
    if (val+0 > r_cores[r]) r_cores[r]=val+0
    r_n[r]+=n
  }
  for (r in r_cores) printf "C|%s|%.2f|%d\n", r, r_cores[r], r_n[r]
  for (h in g_max) printf "M|%-44s|%8.2f|%6d\n", h, g_max[h], g_n[h]
}'

echo "══════ 实测峰值核数（有 PID 者取最后观测值；旧格式取最大值，受核数上限约束）══════"
awk -v ncpu="$NCPU" "$AWK" "$LOG" | grep '^C|' | sort -t'|' -k3 -nr | head -18 |
  awk -F'|' '{printf "  %-40s %7s 核   (累计采样 %s 次)\n", $2, $3, $4}'
echo
echo "══════ 实测峰值内存 ══════"
awk -v ncpu="$NCPU" "$AWK" "$LOG" | grep '^M|' | sort -t'|' -k3 -nr | head -16 |
  awk -F'|' '{printf "  %-44s %7s GB\n", $2, $3}'
