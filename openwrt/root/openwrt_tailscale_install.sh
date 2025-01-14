#!/bin/ash
set -e  # 脚本出错时立即退出
# 用户选择系统架构
echo "请选择系统架构："
echo "1. arm"
echo "2. arm64"
echo "3. amd64"
echo "4. mips"
read -p "请输入选项数字 (1/2/3/4): " arch_choice
# 根据用户选择设置架构变量
case "$arch_choice" in
    1) arch="arm" ;;
    2) arch="arm64" ;;
    3) arch="amd64" ;;
    4) arch="mips" ;;
    *)
        echo "错误：无效的选项！"
        exit 1
        ;;
esac
echo "已选择架构：$arch"
# 获取最新版本号（兼容 BusyBox grep）
latest_version=$(wget -qO- https://pkgs.tailscale.com/stable/ | grep -o 'tailscale_[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 | cut -d'_' -f2)
if [ -z "$latest_version" ]; then
    echo "Failed to fetch latest Tailscale version."
    exit 1
fi
# 构造下载链接
version="${latest_version}_${arch}"
download_url="https://pkgs.tailscale.com/stable/tailscale_${version}.tgz"
# 下载并解压到 /root 目录
echo "Downloading Tailscale ${version}..."
retries=3
while [ $retries -gt 0 ]; do
    if wget -qO- "$download_url" | tar -xz -C /root; then
        break
    else
        retries=$((retries - 1))
        echo "Download failed, retrying... ($retries retries left)"
        sleep 5
    fi
done
if [ $retries -eq 0 ]; then
    echo "Failed to download Tailscale after multiple attempts."
    exit 1
fi
# 移动二进制文件到系统目录
mv /root/tailscale_${version}/tailscale /usr/bin/tailscale
mv /root/tailscale_${version}/tailscaled /usr/sbin/tailscaled
# 删除 /root/systemd 目录及其内容
rm -rf /root/tailscale_${version}/systemd
# 清理临时文件
rm -rf /root/tailscale_${version}
echo "Tailscale ${latest_version} installed to /usr/bin and /usr/sbin!"