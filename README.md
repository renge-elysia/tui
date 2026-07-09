# TUIC 一键安装脚本

用于在常见 Linux VPS 上快速部署 TUIC v5 服务端。脚本会自动下载 `tuic-server`，生成配置与自签 TLS 证书，创建 systemd 或 OpenRC 服务，监听你指定的 UDP 端口，并在安装完成后输出 IPv4 / IPv6 节点链接。

## 特性

- 支持自定义任意合法端口，例如 `443`、`8443`、`2053`
- 默认监听 `[::]:PORT`，支持 IPv4 / IPv6 双栈
- 自动生成 UUID、密码和 TLS 证书
- 支持自签证书、已有 PEM 证书、acme.sh + Cloudflare DNS 自动申请
- 自动识别 VPS 架构并下载对应 `tuic-server` 二进制
- 自动创建、启动并启用 systemd / OpenRC 服务
- 自动输出 TUIC 节点链接，方便复制到客户端
- 支持重新打印节点信息和一键卸载

## 支持系统

脚本面向带 systemd 或 OpenRC 的 Linux VPS，常见发行版包括：

- Debian / Ubuntu
- AlmaLinux / Rocky Linux / CentOS / Fedora
- openSUSE
- Arch Linux
- Alpine Linux

脚本会尝试自动安装基础依赖：`curl`、`openssl`、`ca-certificates`、`coreutils`。

## 一键安装

默认随机生成 UUID 和密码，只需要指定端口：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/renge-elysia/tui/main/install.sh) --port 443
```

如果你的 VPS 没有开放 443 UDP，可以换成其他端口：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/renge-elysia/tui/main/install.sh) --port 8443
```

如果 `raw.githubusercontent.com` 返回 `429`，说明当前 VPS IP 访问 GitHub raw 被限流。可以换用 jsDelivr：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/renge-elysia/tui@main/install.sh) --port 443
```

也可以直接下载仓库后执行：

```bash
curl -fL https://github.com/renge-elysia/tui/archive/refs/heads/main.tar.gz -o tui.tar.gz
tar -xzf tui.tar.gz
bash tui-main/install.sh --port 443
```

安装完成后，终端会输出类似内容：

```text
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
PASSWORD=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
PORT=443
SNI=www.bing.com
CONGESTION_CONTROL=bbr

IPv4=1.2.3.4
TUIC_IPV4_LINK=tuic://...

IPv6=2001:db8::1
TUIC_IPV6_LINK=tuic://...
```

有 IPv6 地址时会输出 IPv6 链接；没有 IPv6 时只输出 IPv4 链接。

## 自定义安装

指定 SNI：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/renge-elysia/tui/main/install.sh) \
  --port 443 \
  --sni example.com
```

指定 UUID 和密码：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/renge-elysia/tui/main/install.sh) \
  --port 443 \
  --uuid 00000000-0000-4000-8000-000000000000 \
  --password 'change-this-password'
```

指定拥塞控制算法：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/renge-elysia/tui/main/install.sh) \
  --port 443 \
  --congestion-control bbr
```

可选值：

- `bbr`
- `cubic`
- `new_reno`

## 配置 TLS 证书

脚本支持三种证书方式：

- 默认自签证书：不传证书参数时自动生成，节点链接会带 `allow_insecure=1`
- 使用已有证书：传入 `--cert-file` 和 `--key-file`
- 自动申请证书：使用 `--acme-dns-cf` 调用 acme.sh，通过 Cloudflare DNS 验证申请

### 方式一：acme.sh + Cloudflare DNS

DNS 验证不需要开放 80/443 端口，适合 NAT VPS、端口转发 VPS、只有随机端口的 VPS。

先准备 Cloudflare 账号邮箱和 Global API Key，然后执行：

```bash
export CF_Key="你的Global_API_Key"
export CF_Email="你的Cloudflare邮箱"

bash <(curl -fsSL https://cdn.jsdelivr.net/gh/renge-elysia/tui@main/install.sh) \
  --port 49255 \
  --domain example.com \
  --acme-dns-cf
```

NAT / 端口转发 VPS 示例：

```bash
export CF_Key="你的Global_API_Key"
export CF_Email="你的Cloudflare邮箱"

bash <(curl -fsSL https://cdn.jsdelivr.net/gh/renge-elysia/tui@main/install.sh) \
  --port 49255 \
  --external-port 30001 \
  --public-host example.com \
  --domain example.com \
  --acme-dns-cf
```

说明：

- `--domain` 会作为证书域名和节点链接里的 SNI
- `--public-host` 是节点链接里的连接地址，NAT VPS 建议填公网域名或公网 IP
- Cloudflare API Key 不要写进 GitHub README、脚本或公开日志

### 方式二：使用已有 PEM 证书

如果你已经有证书和私钥，把它们保存到 VPS 上：

```bash
mkdir -p /root/tuic-cert
nano /root/tuic-cert/cert.pem
nano /root/tuic-cert/private.key
chmod 600 /root/tuic-cert/private.key
```

然后安装：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/renge-elysia/tui@main/install.sh) \
  --port 49255 \
  --domain example.com \
  --cert-file /root/tuic-cert/cert.pem \
  --key-file /root/tuic-cert/private.key
```

脚本会校验证书和私钥是否匹配；不匹配会直接停止安装。

Cloudflare Origin Certificate 也可以用这种方式，但要注意：

- 你需要同时保存 Cloudflare 提供的 Certificate 和 Private Key
- 只贴 Certificate PEM 不够，服务端无法启动
- Cloudflare Origin CA 通常不被普通客户端系统信任，TUIC 客户端仍可能需要允许不安全证书或导入 Origin CA

## NAT VPS / 端口转发 VPS

NAT VPS 通常有两个端口：

- 内网监听端口：服务实际在 VPS 内监听的端口
- 公网映射端口：服务商分配给你的外部访问端口

脚本中的 `--port` 是内网监听端口。节点链接里的公网地址和公网端口用 `--public-host`、`--external-port` 指定。

如果服务商给你的转发规则是：

```text
公网 IP:30001 -> VPS 内网:49255/udp
```

安装命令应写成：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/renge-elysia/tui@main/install.sh) \
  --port 49255 \
  --external-port 30001 \
  --public-host 公网IP或域名
```

如果公网端口和内网监听端口相同，只需要：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/renge-elysia/tui@main/install.sh) \
  --port 49255 \
  --public-host 公网IP或域名
```

NAT VPS 必须确认服务商控制面板里已经转发了对应的 UDP 端口。只转发 TCP 不够，TUIC 需要 UDP。

## 常用命令

重新打印节点信息：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/renge-elysia/tui/main/install.sh) --print
```

查看服务状态：

```bash
systemctl status tuic --no-pager
```

查看运行日志：

```bash
journalctl -u tuic -e --no-pager
```

重启服务：

```bash
systemctl restart tuic
```

卸载：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/renge-elysia/tui/main/install.sh) --uninstall
```

## 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-p, --port` | TUIC UDP 监听端口，安装时必填 | 无 |
| `--external-port` | NAT / 端口转发 VPS 的公网映射端口 | 与 `--port` 相同 |
| `--public-host` | NAT / 端口转发 VPS 的公网 IP 或域名 | 自动检测公网 IP |
| `-u, --uuid` | TUIC 用户 UUID | 随机生成 |
| `-w, --password` | TUIC 用户密码 | 随机生成 |
| `-d, --domain` | 证书域名，未显式传 `--sni` 时也作为 SNI | 无 |
| `-s, --sni` | 节点链接里的 SNI | `--domain` 或 `www.bing.com` |
| `--cert-file` | 已有证书 / fullchain PEM 路径 | 无 |
| `--key-file` | 已有私钥 PEM 路径 | 无 |
| `--acme-dns-cf` | 使用 acme.sh + Cloudflare DNS 自动申请证书 | 关闭 |
| `-c, --congestion-control` | 拥塞控制算法：`bbr`、`cubic`、`new_reno` | `bbr` |
| `-v, --version` | 指定 `tuic-server` release 标签 | `latest` |
| `--no-firewall` | 不自动配置 `ufw` / `firewalld` | 关闭 |
| `--install-dir` | 节点信息保存目录 | `/opt/tuic` |
| `--config-dir` | 配置和证书目录 | `/etc/tuic` |
| `--service-name` | 服务名 | `tuic` |
| `--print` | 输出已保存的节点信息 | 无 |
| `--uninstall` | 卸载服务、配置和二进制文件 | 无 |
| `-h, --help` | 查看帮助 | 无 |

## 安装位置

脚本会写入以下文件：

```text
/usr/local/bin/tuic-server
/etc/tuic/config.json
/etc/tuic/certificate.crt
/etc/tuic/private.key
/etc/systemd/system/tuic.service 或 /etc/init.d/tuic
/opt/tuic/links.txt
```

节点信息保存在：

```text
/opt/tuic/links.txt
```

## 服务端配置

脚本生成的核心配置示例：

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
  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_idle_time": "10s",
  "max_external_packet_size": 1500,
  "send_window": 16777216,
  "receive_window": 8388608,
  "gc_interval": "3s",
  "gc_lifetime": "15s",
  "log_level": "warn"
}
```

## 放行端口

TUIC 基于 QUIC，主要使用 UDP。安装后请确认两处都已放行对应 UDP 端口：

- VPS 系统防火墙，例如 `ufw` 或 `firewalld`
- 云厂商安全组 / 防火墙规则

脚本会自动尝试配置 `ufw` 和 `firewalld`，但云厂商安全组通常需要在控制台手动放行。

## 注意事项

- 默认自签证书和 Cloudflare Origin Certificate 通常需要客户端允许不安全证书；公开信任证书可减少这类兼容问题。
- 如果 VPS 没有 IPv6 地址，IPv6 链接不会输出。
- 如果系统不支持 IPv4-mapped IPv6 socket，双栈监听可能无法同时覆盖 IPv4 和 IPv6。
- 如果 systemd 系统安装失败，先查看 `systemctl status tuic --no-pager` 和 `journalctl -u tuic -e --no-pager`。
- 如果 Alpine/OpenRC 安装失败，先查看 `rc-service tuic status` 和系统日志。

## 上游项目

- TUIC 协议：[tuic-protocol/tuic](https://github.com/tuic-protocol/tuic)
- `tuic-server` 发布页：[tuic-protocol/tuic/releases](https://github.com/tuic-protocol/tuic/releases)
