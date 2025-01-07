# openwrt_tailscale_install

## tailscale简单介绍

Tailscale 是一种基于 WireGuard 协议局域网组网的现代 VPN 工具。

## 多个压缩包版本的注释



## openwrt上需要执行的命令

`tar -xzvf filename -C /`

`opkg update`

`opkg install libustream-openssl ca-bundle kmod -tun`

`./openwrt_tailscale_install.sh`  <!--假如使用二进制打包版不需要运行一键安装脚本-->

`/etc/init.d/tailscale start`

`tailscale up --advertise-routes=192.168.0.0/24 --accept-routes=true --accept-dns=false`

`/etc/init.d/tailscale enable`

`ls /etc/rc.d/S*tailscale*`

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

以我手上的REDMIax6000路由器为例，其tmp空间充足而overlay只有40M左右 因此可以将tailscale的二进制文件tailscale和tailscaled放在tmp文件夹下 重启后tmp目录的二进制文件会被清楚 通过自启脚本重新把二进制文件放入tmp目录并启动

`tar -xzvf filename -C /`

opkg需要安装的依赖可以手动下载并opkg install filename.ipk

ca-bundle已安装 kmod-tun我碰到的情况是openwrt的realse依赖不存在 缺少这个应该是影响出口节点

`/etc/init.d/tailscale start`

`/tmp/tailscale up --advertise-routes=192.168.0.0/24 --accept-routes=true --accept-dns=false`

`/etc/init.d/tailscale enable`

`ls /etc/rc.d/S*tailscale*`

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>复制</title>
  <style>
    pre {
      position: relative;
      background-color: #f5f5f5;
      padding: 10px;
      border-radius: 5px;
      font-family: monospace;
    }
    button {
      position: absolute;
      top: 5px;
      right: 5px;
      background-color: #007bff;
      color: white;
      border: none;
      padding: 5px 10px;
      border-radius: 3px;
      cursor: pointer;
    }
    button:hover {
      background-color: #0056b3;
    }
  </style>
</head>
<body>

<!-- 代码块 -->
<pre>
  <code id="code-block">
tar x -zvC / -f openwrt-tailscale-enabler-&lt;tag&gt;.tgz
  </code>
  <button onclick="copyCode()">复制代码</button>
</pre>

<!-- JavaScript 实现复制功能 -->
<script>
  function copyCode() {
    const codeBlock = document.getElementById('code-block');
    const textToCopy = codeBlock.innerText;

    navigator.clipboard.writeText(textToCopy)
      .then(() => alert('代码已复制!'))
      .catch(() => alert('复制失败，请手动复制。'));
  }
</script>

</body>
</html>
```

