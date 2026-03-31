# hello

Small HTTP service (`/` JSON, `/health`). Logging uses [`log/slog`](https://pkg.go.dev/log/slog) with environment variables:

| Variable | Description |
|----------|-------------|
| `LISTEN_ADDR` | Listen address (default `:8080`) |
| `LOG_LEVEL` | `debug`, `info`, `warn`, `error` (default `info`) |
| `LOG_FORMAT` | `text` or `json` (default `text`) |
| `LOG_FILE` | Optional path; when set, same log lines go to stdout and this file (append) |

On the bootc image, `hello.service` uses the three-tier EnvironmentFile convention:
- **Tier 1** (immutable defaults): `/usr/share/bootc-testboot/hello/hello.env` — `LISTEN_ADDR`, `LOG_LEVEL`, `LOG_FORMAT`
- **Tier 2** (shared infra secrets): commented out — hello does not use MongoDB/Valkey/RabbitMQ. Future apps uncomment the infra env files they need (e.g., `mongodb.env`, `valkey.env`)
- **Tier 3** (per-app overrides): `/var/lib/bootc-testboot/hello/hello.secrets.overrides` — operator-managed, optional

`LOG_FILE` is set inline via `Environment=` (not in the env file) to keep log path ownership tied to `LogsDirectory=`.

See [docs/project/004-testing-guide.md](../../docs/project/004-testing-guide.md) for journal vs files and logrotate.
