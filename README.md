# openwrt_tailscale_install

## tailscale简单介绍

Tailscale 是一种基于 WireGuard 协议局域网组网的现代 VPN 工具。

## 一键脚本

脚本: `openwrt/root/openwrt_tailscale_install.sh`（解包后位于 `/root/openwrt_tailscale_install.sh`）

```sh
wget https://github.com/xiki45/openwrt_tailscale_install/releases/download/v1.0/openwrt_tailscale_sh.tgz
tar -xzvf openwrt_tailscale_sh.tgz -C /
sh /root/openwrt_tailscale_install.sh
```

不带参数跑就行，脚本自己完成三件事：

1. **平台识别**：读 `/etc/openwrt_release` 的 `DISTRIB_ARCH`（读不到就用 `uname -m` + ELF 字节序判大小端），自动映射到官方静态包架构
   `386 / amd64 / arm / arm64 / geode / mips / mipsle / mips64 / mips64le / riscv64`，不再手选。
   例如 `aarch64_cortex-a53 -> arm64`、`mipsel_24kc -> mipsle`、`arm_cortex-a9 -> arm`。
2. **依赖补齐（ipk）**：先实测能力，缺什么补什么，安装顺序是 *opkg 源 → 本地 ipk → 按发行版信息拉 ipk*。

   | 需求 | 判断方式 | 补什么 |
   | --- | --- | --- |
   | https 抓取能力 | 实测能不能抓 `pkgs.tailscale.com` | `uclient-fetch`（或 `wget-ssl`/`curl`）+ `libustream-openssl\|wolfssl\|mbedtls` + `ca-bundle` |
   | tun 设备 | 实测 `ip tuntap add` / `/dev/net/tun`（不是看包在不在） | `kmod-tun`；系统 tun 内建时跳过 |
   | 子网路由/出口节点 | 看有没有 `nft` 或 `iptables` | 只告警，不擅自装 |

   `kmod-tun` 只在 `targets/<target>/<subtarget>/packages` 这个 feed 里、且 `Depends: kernel (=<版本>-<hash>)`，
   自制固件/换过内核时源里装不上，脚本会按 `/etc/openwrt_release` 推导出设备自己的 target feed 索引去找对应 ipk；
   实在拿不到就明确告警（此时子网路由与出口节点不可用，普通组网仍可用 `--userspace` 走 `--tun=userspace-networking`）。
3. **安装 / 更新**：抓 `pkgs.tailscale.com` 上该架构的最大版本号与本机版本比对——相同就退出，不同就更新，
   本机版本更高时拒绝降级（`--force` 可强降）。下载后校验 `sha256`，解包只取两个二进制，
   先冒烟测试（真跑一次 `--version`）再替换，架构选错/包损坏不会先删掉旧文件。
   最后写 `/etc/init.d/tailscale`（procd，带 `--port 41641 --state /etc/config/tailscaled.state --statedir /etc/tailscale/`）、
   `enable` 开机自启并启动，`tailscale up` 的参数提示里会带上探测到的 LAN 网段。

### 选项

```
-a, --arch ARCH    强制架构 (默认自动识别)
-v, --version VER  安装指定版本，例如 1.102.4
-u, --unstable     使用 unstable 通道 (默认 stable)
-f, --force        已是最新也重装；允许降级
-t, --tmp          强制 /tmp 模式
-d, --dir DIR      /tmp 模式的持久化目录 (默认依次尝试 /data /userdisk /root /etc)
-p, --prefix DIR   路径前缀，chroot/测试用
-n, --no-deps      跳过依赖补齐
    --userspace    改用 --tun=userspace-networking
```

更新就是再跑一次脚本；`tailscale` 的状态在 `/etc/config/tailscaled.state`，升级不会丢登录态。

> 前置条件：`/etc` 必须可写且能扛过重启（服务文件、自启链接、tailscaled 状态都在这里）。
> 脚本会真实写入探测 `/etc`、`/etc/init.d`、`/etc/rc.d`、`/etc/config`，不可写就直接报错退出并指出是哪个目录。
> 小米原厂固件不挂 overlayfs 时 `/etc` 是只读的，必须先挂载（见下文小米章节）。

### 空间与 /tmp 模式

两个二进制解包后约 70–80MB。脚本先看 `/usr` 所在分区剩余空间：

- 够（≥90MB）：系统模式，二进制直接进 `/usr/sbin/tailscaled` 与 `/usr/bin/tailscale`；
- 不够（小米路由器 overlay 常只有 40MB）：自动切 **/tmp 模式**，二进制放 tmpfs，同时在持久化目录（默认 `/data`，没有就依次试 `/userdisk`、`/root`、`/etc`）留一份副本，
  并在 `/usr/bin`、`/usr/sbin` 建软链；服务文件里带自愈逻辑，重启后 tmpfs 被清空时会从持久化目录把二进制拷回来再启动——
  不再需要自己在 `auto_ssh.sh` 里写搬运逻辑。

### 输出示例

```
[i] 架构: arm64 (uname -m=aarch64, DISTRIB_ARCH=aarch64_cortex-a53)
[i] 系统: OpenWrt 23.05.5 / mediatek/filogic / aarch64_cortex-a53
[i] https 抓取能力: 就绪
[i] tun 设备: 就绪
[i] 目标版本: 1.102.4 (stable 通道最新)
[i] 版本变化: 1.100.0 -> 1.102.4
[i] sha256 校验通过
[i] 冒烟测试通过: tailscale 1.102.4
[i] 安装模式: 系统模式 (/usr/sbin/tailscaled + /usr/bin/tailscale)

完成: Tailscale 1.102.4 / 架构 arm64 / 1.100.0 -> 1.102.4
登录组网: tailscale up --advertise-routes=192.168.41.0/24 --accept-routes --accept-dns=false
```

## 安装后

脚本已经 `enable` 了开机自启（`/etc/rc.d/S99tailscale`）。剩下的只是登录组网：

```sh
tailscale up --advertise-routes=192.168.0.0/24 --accept-routes --accept-dns=false
```

`--advertise-routes` 要填自己实际的 LAN 网段（脚本会打印建议值），并且在 Tailscale 管理后台批准该路由。

手动等价操作（脚本不在时的参考）：

```sh
opkg update
opkg install libustream-openssl ca-bundle kmod-tun
/etc/init.d/tailscale start
/etc/init.d/tailscale enable
```

## tailscale启动命令解释

1. `--advertise-routes=192.168.41.0/24`

  - **含义**：此参数用于在 Tailscale 网络中宣传（advertise）一个特定的子网。在这个例子中，192.168.41.0/24 这个子网将被宣传。

  - **作用**：其他连接到 Tailscale 网络的设备将知道这个子网的存在，并可以通过这个节点访问该子网中的设备。

2. `--accept-routes=true`

  - **含义**：此参数允许接受由其他 Tailscale 节点宣传的路由。

  - **作用**：启用这个选项后，设备将会接受其他 Tailscale 节点提供的路由信息，这样可以访问这些节点所在的子网。

3. `--accept-dns=false`

  - **含义**：此参数拒绝使用由 Tailscale 提供的 DNS 设置。

  - **作用**：启用这个选项后，设备将不会使用 Tailscale 网络中的 DNS 服务器，而是使用本地配置的 DNS 服务器。

4. `--advertise-exit-node`

  - **含义**：此参数将当前设备宣传为出口节点（exit node）。

  - **作用**：启用这个选项后，其他 Tailscale 设备可以选择通过这个设备的互联网连接访问互联网，即该设备将作为 Tailscale 网络的出口。

- 对于linux，默认情况下不会自动接受其他节点的路由信息，因此需要显式地添加 `--accept-routes` 以便接受并路由这些子网信息，使得云服务器能够访问这些宣传的子网。

## 小米路由器使用tailscale

以 REDMI AX6000 路由器为例，其 tmp 空间充足而 overlay 只有 40M 左右，因此二进制不能常驻 `/usr`。
**现在直接跑同一个一键脚本即可**，脚本检测到 `/usr` 空间不足会自动进入 /tmp 模式（放 tmpfs + `/data` 持久化副本 + 开机自动恢复），
不需要再手工把二进制塞进 `/tmp`、也不用自己写自启搬运。

仍然需要手动做的一步是挂载 overlayfs：**不挂载 `/etc` 是只读的，服务文件 `/etc/init.d/tailscale`、自启链接 `/etc/rc.d/S99tailscale`、tailscaled 的状态 `/etc/config/tailscaled.state` 与 `/etc/tailscale/` 全都没法写入**（不挂载的话即使硬塞进 `/tmp` 跑起来，重启也会丢登录态，等于每次都要重新认证）。
脚本启动时会用真实写入探测 `/etc`、`/etc/init.d`、`/etc/rc.d`、`/etc/config` 是否可写，不可写就直接报错退出并指出是哪个目录，不会白下载 35MB。

挂载方法（把以下代码添加进 `auto_ssh.sh`）：

```
#Mount overlay
[ -e /data/overlay ] || mkdir /data/overlay
[ -e /data/overlay/upper ] || mkdir /data/overlay/upper
[ -e /data/overlay/work ] || mkdir /data/overlay/work
mount --bind /data/overlay /overlay
. /lib/functions/preinit.sh
fopivot /overlay/upper /overlay/work /rom 1

#Fixup miwifi misc, and DO NOT use /overlay/upper/etc instead, /etc/uci-defaults/* may be already removed
/bin/mount -o noatime,move /rom/data /data 2>&-
/bin/mount -o noatime,move /rom/etc /etc 2>&-
/bin/mount -o noatime,move /rom/ini /ini 2>&-
/bin/mount -o noatime,move /rom/userdisk /userdisk 2>&-
```

查看挂载是否成功

```
df -h
```

之后：

```sh
sh /root/openwrt_tailscale_install.sh        # 自动识别 arm64、补依赖、更新到最新版、落到 /tmp 模式
/tmp/tailscale up --advertise-routes=192.168.0.0/24 --accept-routes --accept-dns=false
```

`tailscale`/`tailscaled` 会被软链到 `/usr/bin`、`/usr/sbin`，所以也可以直接敲 `tailscale`；
但因为二进制在 tmpfs，`up` 时用绝对路径 `/tmp/tailscale` 更稳妥。

如果 `/etc/rc.d` 下没有 `S99tailscale`，运行以下命令（脚本正常跑完时会自动建好）：

```sh
ln -s /etc/init.d/tailscale /etc/rc.d/S99tailscale
```

`xiaomi/` 目录是早期的手动备份包（旧流程：手动把二进制放进 `/tmp`）与当年用到的 `libustream-openssl` ipk；
`xiaomi/ipk/` 里的 ipk 仍可用——脚本补依赖时会先找本地 ipk，找不到才联网拉。
旧流程遗留的 `/etc/init.d/tailscale`（写死 `/tmp` 路径、无开机恢复）会被脚本生成的版本覆盖，
被覆盖前若文件不是脚本管理的，会先备份成 `/etc/init.d/tailscale.bak`。
