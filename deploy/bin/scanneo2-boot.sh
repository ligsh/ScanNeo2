#!/bin/bash
# 实例重建（或系统盘被换掉）后运行一次，把"不在数据盘上"的东西补回来。
# 数据盘上已有的（仓库 / 25 个 conda 环境 / 参考数据 / wrapper 缓存 / Miniforge）
# 随数据盘走，不需要恢复。
set -euo pipefail
echo "[1/6] 检查数据盘"; mountpoint -q /data || { echo "  错误: /data 未挂载"; exit 1; }; echo "  ✓"
echo "[2/6] 恢复 PyPI 国内镜像（否则 pip 会卡死在 PyPI）"
sudo cp /data/etc/sys-backup/pip.conf /etc/pip.conf; echo "  ✓ /etc/pip.conf"
echo "[3/6] 恢复 git URL 重写（否则 snakemake 更新 wrapper 缓存时挂在 github）"
sudo git config --system url."/data/cache/wrappers-mirror.git".insteadOf \
  "https://github.com/snakemake/snakemake-wrappers"; echo "  ✓ /etc/gitconfig"
echo "[4/6] snakemake 源码缓存软链回数据盘"
mkdir -p /data/cache/snakemake /home/ecs-user/.cache
ln -sfn /data/cache/snakemake /home/ecs-user/.cache/snakemake; echo "  ✓ ~/.cache/snakemake"
echo "[5/6] 恢复 shadowsocks 代理"
if [ -x /usr/bin/ss-local ]; then
  sudo cp /data/etc/sys-backup/ss-local.service /etc/systemd/system/ss-local.service
  sudo cp /data/etc/sys-backup/shadowsocks-client-config.json /etc/shadowsocks-libev/client-config.json
  sudo chmod 600 /etc/shadowsocks-libev/client-config.json
  sudo systemctl daemon-reload && sudo systemctl enable --now ss-local
  echo "  ✓ ss-local: $(systemctl is-active ss-local)"
else
  echo "  ! 未装 shadowsocks-libev，跳过（需要时: sudo apt install shadowsocks-libev）"
fi
echo "[6/6] 恢复 SSH 授权（ecs01 直连用）"
mkdir -p /home/ecs-user/.ssh && chmod 700 /home/ecs-user/.ssh
cp /data/etc/sys-backup/authorized_keys /home/ecs-user/.ssh/authorized_keys
chmod 600 /home/ecs-user/.ssh/authorized_keys; echo "  ✓ $(wc -l < /home/ecs-user/.ssh/authorized_keys) 个密钥"
echo; echo "引导完成。下一步: /data/bin/scanneo2-run.sh -c 32"
