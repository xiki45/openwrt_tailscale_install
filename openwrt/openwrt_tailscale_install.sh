#!/bin/sh

set -e

# 获取系统架构
arch=$(uname -m)
case "$arch" in
    armv7l)  arch="arm" ;;
    aarch64) arch="arm64" ;;
    x86_64)  arch="amd64" ;;
    mips*)   arch="mips" ;;
    *)       echo "Unsupported architecture: $arch"; exit 1 ;;
esac

# 获取最新版本号
latest_version=$(wget -qO- https://pkgs.tailscale.com/stable/ | grep -oP 'tailscale_\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$latest_version" ]; then
    echo "Failed to fetch latest Tailscale version."
    exit 1
fi

# 构造下载链接
version="${latest_version}_${arch}"
download_url="https://pkgs.tailscale.com/stable/tailscale_${version}.tgz"

# 下载并解压到 /root 目录
echo "Downloading Tailscale ${version}..."
wget -qO- "$download_url" | tar -xz -C /root

# 移动二进制文件到系统目录
mv /root/tailscale_${version}/tailscale /usr/bin/tailscale
mv /root/tailscale_${version}/tailscaled /usr/sbin/tailscaled

# 删除 /root/systemd 目录及其内容
rm -rf /root/tailscale_${version}/systemd

# 清理临时文件
rm -rf /root/tailscale_${version}

echo "Tailscale ${latest_version} installed to /usr/bin and /usr/sbin!"