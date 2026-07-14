# Mi BE6500 Pro Monitor

English | [简体中文](README.md)

A lightweight performance monitor for SSH-unlocked Xiaomi BE6500 Pro routers.
One static ARM64 binary collects CPU, memory, and thermal data while serving a
JSON API and an embedded responsive web dashboard.

> [!CAUTION]
> This project supports and has only been verified on the Xiaomi BE6500 Pro.
> Other routers may expose different thermal zone counts, sensor names,
> persistent storage paths, and boot mechanisms. Owners of other models must
> review and adapt the source code themselves. Do not install it if you do not
> understand the risks of those differences.

## Features

- Configurable CPU, memory, and thermal zone sampling
- Embedded responsive dark dashboard for desktop and mobile browsers
- Dynamic ECharts timelines, temperature chart, and hover details
- `GET /metrics.json` JSON metrics endpoint
- `GET /health` health endpoint
- Interactive `rmmon` management menu
- Start, stop, restart, logs, interval, and port controls
- Xiaomi boot integration and complete uninstallation

## Requirements

- Xiaomi BE6500 Pro with SSH unlocked and `root` access
- Linux `aarch64`/`arm64`
- A writable `/data/other_vol`
- Access to `raw.githubusercontent.com`
- `curl` or `wget`

The application files are installed under `/data/other_vol/router-monitor`.
When enabled, boot integration and the command alias also use Xiaomi's
`/data/auto_start.sh`, a UCI firewall include, and `/etc/profile`. The
uninstaller removes these entries.

## One-line installation

After signing in to the router over SSH, use GitHub Raw first:

```sh
export url='https://raw.githubusercontent.com/MisakaXeon/Mi-BE6500PRO-Monitor/main' \
  && sh -c "$(curl -kfsSL $url/scripts/install.sh)" \
  && . /etc/profile >/dev/null 2>&1
```

If GitHub Raw is unavailable or unstable on your network, use jsDelivr:

```sh
export url='https://cdn.jsdelivr.net/gh/MisakaXeon/Mi-BE6500PRO-Monitor@main' \
  && sh -c "$(curl -kfsSL $url/scripts/install.sh)" \
  && . /etc/profile >/dev/null 2>&1
```

The installer uses `url` for the binary and all management scripts, so the
entire installation uses jsDelivr with this command. Branch content may be
temporarily stale due to CDN caching; replace `@main` with a published version
tag when an immutable installation source is required.

The installer requires you to type `BE6500PRO` before continuing. It then asks
for the sampling interval, listening port, and whether to start immediately.
Defaults are 10 seconds and TCP port 9898.

## Usage

Open the management menu:

```sh
rmmon
```

Direct commands are also available:

```sh
rmmon status
rmmon metrics
rmmon restart
rmmon log 100
```

Open the dashboard or JSON endpoint:

```text
http://ROUTER_IP:9898/
http://ROUTER_IP:9898/metrics.json
```

## Uninstall

Run `rmmon`, select `10. Uninstall`, and type `YES` when prompted.

## Build from source

Go 1.26 or a compatible version is required:

```sh
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
  -trimpath -ldflags="-s -w" -o bin/router-monitor_linux_arm64 .
```

The dashboard is compiled into the binary with `go:embed`; no separate static
files are required on the router.

## Security

The service listens on `0.0.0.0` by default and does not authenticate its
metrics endpoint. Use it only on a trusted LAN and never expose its port to the
public Internet. The installer downloads and executes code as root, so review
[`scripts/install.sh`](scripts/install.sh) before running it.

## License

[MIT](LICENSE)

