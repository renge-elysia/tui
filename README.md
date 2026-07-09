# TUIC VPS Installer

一个用于常见 Linux VPS 的 TUIC v5 一键安装脚本。脚本会安装 `tuic-server`，生成自签 TLS 证书，创建 systemd 服务，监听指定 UDP 端口，并把 IPv4 / IPv6 节点链接输出到终端。

## 功能

- 指定任意合法端口监听 TUIC：`--port 443`
- 默认监听 `[::]:PORT`，开启 `dual_stack` 和 IPv6 UDP relay
- 自动生成 UUID、密码和自签证书
- 自动识别 Linux 架构并下载 release 二进制
- 自动创建并启动 systemd 服务
- 自动输出 IPv4 和 IPv6 节点链接
- 支持重新打印节点信息和卸载

## 快速使用

在 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/install.sh) --port 443
```

如果是在克隆后的项目目录中执行：

```bash
sudo bash install.sh --port 443
```

安装完成后，终端会输出类似：

```text
TUIC_IPV4_LINK=tuic://...
TUIC_IPV6_LINK=tuic://...
```

TUIC 基于 QUIC，主要使用 UDP。请确认 VPS 云厂商安全组也放行了对应 UDP 端口。

## 常用命令

指定端口、SNI 和拥塞控制：

```bash
sudo bash install.sh --port 8443 --sni example.com --congestion-control bbr
```

指定 UUID 和密码：

```bash
sudo bash install.sh --port 443 \
  --uuid 00000000-0000-4000-8000-000000000000 \
  --password 'change-this-password'
```

重新输出节点信息：

```bash
sudo bash install.sh --print
```

查看服务状态：

```bash
systemctl status tuic --no-pager
```

卸载：

```bash
sudo bash install.sh --uninstall
```

## 参数

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-p, --port` | TUIC UDP 监听端口，安装时必填 | 无 |
| `-u, --uuid` | TUIC 用户 UUID | 随机生成 |
| `-w, --password` | TUIC 用户密码 | 随机生成 |
| `-s, --sni` | 自签证书 CN 和链接里的 SNI | `www.bing.com` |
| `-c, --congestion-control` | `cubic`、`new_reno` 或 `bbr` | `bbr` |
| `-v, --version` | `tuic-server` release 标签 | `latest` |
| `--no-firewall` | 不自动配置 ufw/firewalld | 关闭 |
| `--install-dir` | 节点信息保存目录 | `/opt/tuic` |
| `--config-dir` | 配置和证书目录 | `/etc/tuic` |
| `--service-name` | systemd 服务名 | `tuic` |
| `--print` | 输出已保存节点信息 | 无 |
| `--uninstall` | 卸载服务、配置和二进制 | 无 |

## 安装后的文件

```text
/usr/local/bin/tuic-server
/etc/tuic/config.json
/etc/tuic/certificate.crt
/etc/tuic/private.key
/etc/systemd/system/tuic.service
/opt/tuic/links.txt
```

## 生成的服务端配置

脚本生成的核心配置如下：

```json
{
  "server": "[::]:443",
  "users": {
    "UUID": "PASSWORD"
  },
  "certificate": "/etc/tuic/certificate.crt",
  "private_key": "/etc/tuic/private.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "udp_relay_ipv6": true,
  "zero_rtt_handshake": false,
  "dual_stack": true,
  "log_level": "warn"
}
```

## 注意事项

- 如果 VPS 没有 IPv6 地址，脚本只会输出 IPv4 链接。
- 如果系统内核或发行版没有启用 IPv4-mapped IPv6 socket，`dual_stack` 可能无法同时监听 IPv4 和 IPv6。这种情况下建议优先使用支持 dual-stack 的常见发行版，如 Debian、Ubuntu、AlmaLinux、Rocky Linux。
- 脚本生成的是自签证书，因此节点链接包含 `allow_insecure=1`。
- 自动防火墙配置只处理 `ufw` 和 `firewalld`。云厂商安全组需要手动放行 UDP 端口。

## 上游

- TUIC 协议仓库：[tuic-protocol/tuic](https://github.com/tuic-protocol/tuic)
- `tuic-server` release：[tuic-protocol/tuic/releases](https://github.com/tuic-protocol/tuic/releases)
