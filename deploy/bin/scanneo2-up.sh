#!/bin/bash
#
# 开工自检：启动实例、把快照建成的数据盘挂到 /data 之后跑这个，确认这台机器真的能开工。
#
# 它做四件事：确认 /data 已挂载 → 恢复系统盘侧的配置 → 自检环境与参考数据 → 试解析 DAG。
# 全绿才提示可以跑；任何一项不过都以非零码退出，避免跑到一半才发现盘是旧的。
#
# 用法: /data/bin/scanneo2-up.sh
set -uo pipefail

PASS=0; FAIL=0

# 前置：新实例是干净系统，rclone 与 tcsh 都要手动装（它们不在数据盘里）。
# 不先查这个的话，后面"OSS 凭据不可用"的报错会误导人——凭据没问题，是工具没装。
#
# tcsh 尤其不能漏：netMHCpan / netMHCIIpan 是 `#! /bin/tcsh` 脚本，缺 tcsh 时内核 exec
# 失败、Python 报成误导性的 FileNotFoundError，全部预测批次静默丢弃 → 0 新抗原，
# 而 Snakemake 仍报"完成、0 错误"（2026-10-14 因此白跑 6h20m）。
# 它必须在这里拦下——这是唯一能防住那个静默失败的地方。
_missing=""
for _b in rclone tcsh; do
    command -v "$_b" >/dev/null 2>&1 || _missing="$_missing $_b"
done
if [ -n "$_missing" ]; then
    printf '\n✗ 缺少:%s。新实例上先执行：\n\n    sudo apt install -y rclone shadowsocks-libev tmux tcsh\n\n然后重跑本脚本。\n' "$_missing"
    exit 1
fi
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n[%s] %s\n' "$1" "$2"; }

step 1/4 "数据盘"
mountpoint -q /data || { echo "  /data 未挂载，尝试 mount -a"; sudo mount -a 2>/dev/null || true; }
if mountpoint -q /data; then
    ok "/data 已挂载（可用 $(df -h /data | awk 'NR==2{print $4}')）"
else
    bad "/data 未挂载 —— 请在控制台把快照建成的数据盘挂到本实例，再运行本脚本"
    echo; echo "自检未通过。"; exit 1
fi
if [ -d /data/ScanNeo2 ] && [ -d /data/miniforge3 ]; then ok "仓库与 Miniforge 都在"; else bad "/data 里缺仓库或 Miniforge —— 这块盘不对？"; fi

step 2/4 "恢复系统盘侧的配置"
if [ -x /data/bin/scanneo2-boot.sh ]; then
    /data/bin/scanneo2-boot.sh | sed 's/^/  /' && ok "boot 完成" || bad "boot 失败"
else
    bad "找不到 /data/bin/scanneo2-boot.sh"
fi

step 3/4 "环境与参考数据"
export PATH=/data/miniforge3/envs/scanneo2/bin:/data/miniforge3/bin:$PATH
n=$(ls -d /data/ScanNeo2/.snakemake/conda/*_/ 2>/dev/null | wc -l)
[ "$n" -ge 20 ] && ok "conda 环境 $n 个" || bad "conda 环境只有 $n 个（期望 25 个）"
command -v snakemake >/dev/null && ok "snakemake $(snakemake --version)" || bad "snakemake 不在 PATH"
for f in refs/genome_tmp.fasta refs/genome_tmp.gtf refs/peptide.fasta vep/cache/homo_sapiens; do
    [ -e "/data/ScanNeo2/resources/$f" ] && ok "resources/$f" || bad "缺 resources/$f"
done
set -a; . /data/etc/oss.env; set +a
if rclone --config /data/etc/rclone.conf lsl myoss:ligsh-bucket-01/ScanNeo2/resources/r111/MANIFEST.tsv >/dev/null 2>&1; then
    ok "OSS 凭据可用"
else
    bad "OSS 凭据不可用（rclone 读不到镜像）—— 下载会 403"
fi

step 4/4 "DAG 能否解析"
if (cd /data/ScanNeo2 && timeout 300 snakemake -n -c1 >/tmp/scanneo2-up-dryrun.log 2>&1); then
    ok "dry-run 通过（日志 /tmp/scanneo2-up-dryrun.log）"
else
    bad "dry-run 失败 —— 看 /tmp/scanneo2-up-dryrun.log"
fi

echo
echo "════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
    echo "自检全绿（$PASS 项）。可以开工："
    echo
    echo "  /data/bin/scanneo2-run.sh -c <核数>"
    echo
    echo "本机 $(nproc) 核 / $(free -g | awk '/^Mem:/{print $2}') GB 内存。"
    echo "重活（STAR 索引 64GB、arriba 128GB）需要大机型——如果是 2 核小机器，只适合建环境或下数据。"
else
    echo "自检未通过：$FAIL 项失败，先解决再开工。"
    exit 1
fi
