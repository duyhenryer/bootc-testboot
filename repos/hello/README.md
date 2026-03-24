# hello

Small HTTP service (`/` JSON, `/health`). Logging uses [`log/slog`](https://pkg.go.dev/log/slog) with environment variables:

| Variable | Description |
|----------|-------------|
| `LISTEN_ADDR` | Listen address (default `:8080`) |
| `LOG_LEVEL` | `debug`, `info`, `warn`, `error` (default `info`) |
| `LOG_FORMAT` | `text` or `json` (default `text`) |
| `LOG_FILE` | Optional path; when set, same log lines go to stdout and this file (append) |

On the bootc image, `hello.service` sets `LOG_FILE=/var/log/bootc-testboot/hello/hello.log` and `LogsDirectory=bootc-testboot/hello` so the dynamic service user can write without root.

See [docs/project/007-testing-guide-and-registry.md](../../docs/project/007-testing-guide-and-registry.md) for journal vs files and logrotate.
