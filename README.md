# Mi BE6500 Pro Monitor

[English](README_EN.md) | 简体中文

面向已解锁 SSH 的小米 BE6500 Pro 的轻量级性能监控程序。单个静态 ARM64
二进制提供 CPU、内存和温度采集、JSON 接口以及内嵌的响应式 Web 面板。

> [!CAUTION]
> 本项目仅支持并仅在小米 BE6500 Pro 上完成验证。其他路由器的 thermal zone
> 数量、传感器命名、持久化分区和开机自启机制可能不同。非同型号设备请先阅读并
> 自行修改源码；如果不清楚这些差异可能造成的后果，请不要安装或折腾。

## 功能

- 每隔指定秒数采集 CPU、内存和所有可读取的 thermal zone
- 内嵌深色响应式 Web 面板，桌面与手机浏览器均可使用
- ECharts 动态折线图、温度分区图和悬停详情
- `GET /metrics.json` JSON 数据接口
- `GET /health` 健康检查接口
- `rmmon` 交互式管理菜单
- 启动、停止、重启、日志、间隔和端口设置
- 小米路由器开机自启管理与完整卸载

## 环境要求

- 小米 BE6500 Pro
- 已解锁 SSH，使用 `root` 登录
- Linux `aarch64`/`arm64`
- `/data/other_vol` 存在且可写
- 路由器能够访问 `raw.githubusercontent.com`
- 已安装 `curl` 或 `wget`

程序只在 `/data/other_vol/router-monitor` 安装自身文件。开机自启和快捷命令会按
用户选择写入小米系统的 `/data/auto_start.sh`、UCI 防火墙 include 和
`/etc/profile`；卸载时会清理这些项目。

## 一键安装

SSH 登录路由器后优先使用 GitHub Raw：

```sh
export url='https://raw.githubusercontent.com/MisakaXeon/Mi-BE6500PRO-Monitor/main' \
  && sh -c "$(curl -kfsSL $url/scripts/install.sh)" \
  && . /etc/profile >/dev/null 2>&1
```

如果 GitHub Raw 在当前网络无法访问或下载不稳定，可改用 jsDelivr：

```sh
export url='https://cdn.jsdelivr.net/gh/MisakaXeon/Mi-BE6500PRO-Monitor@main' \
  && sh -c "$(curl -kfsSL $url/scripts/install.sh)" \
  && . /etc/profile >/dev/null 2>&1
```

`url` 会同时作为二进制文件和管理脚本的下载源，因此使用上述命令后，整个安装
过程都会通过 jsDelivr 完成。分支内容可能存在 CDN 缓存延迟；需要固定版本时，
可将 `@main` 替换为仓库中已发布的版本标签。

安装器会要求输入 `BE6500PRO` 确认型号，然后设置采集间隔、监听端口以及是否立即
启动。默认端口为 `9898`，默认采集间隔为 `10` 秒。

若系统只有 `wget`，也可以将下方 `url` 替换为上述 jsDelivr 地址：

```sh
export url='https://raw.githubusercontent.com/MisakaXeon/Mi-BE6500PRO-Monitor/main' \
  && wget --no-check-certificate -qO /tmp/router-monitor-install.sh "$url/scripts/install.sh" \
  && sh /tmp/router-monitor-install.sh \
  && rm -f /tmp/router-monitor-install.sh \
  && . /etc/profile >/dev/null 2>&1
```

## 使用

安装完成后输入：

```sh
rmmon
```

也可直接使用：

```sh
rmmon status
rmmon metrics
rmmon restart
rmmon log 100
```

浏览器访问：

```text
http://路由器IP:9898/
http://路由器IP:9898/metrics.json
```

示例接口数据：

```json
{
  "time": 1783776000,
  "refresh_interval_seconds": 10,
  "cpu": {"usage_percent": 4.2},
  "memory": {
    "total_mb": 863.2,
    "used_mb": 515.8,
    "available_mb": 347.4,
    "usage_percent": 59.8
  },
  "temperatures": [
    {"zone": "thermal_zone0", "type": "tsens_tz_sensor11", "celsius": 68.7}
  ]
}
```

## 卸载

运行 `rmmon`，选择 `10. 卸载`，再按提示输入 `YES`。卸载会停止程序、关闭
开机自启、删除快捷命令及 `/data/other_vol/router-monitor`。

## 从源码构建

需要 Go 1.26 或兼容版本：

```sh
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
  -trimpath -ldflags="-s -w" -o bin/router-monitor_linux_arm64 .
```

Web 面板通过 `go:embed` 编译进二进制，无需在路由器上单独部署静态文件。

## 安全说明

服务默认监听 `0.0.0.0`，且指标接口没有身份验证。它只应在可信局域网内使用，
不要将端口映射到公网。安装命令从 GitHub 下载并以 root 身份执行，建议在执行前
先阅读 [`scripts/install.sh`](scripts/install.sh)。

## 许可证

[MIT](LICENSE)

