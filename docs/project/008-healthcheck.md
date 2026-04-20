# Hello & Worker: healthcheck behavior and monitoring options

This document evaluates how HTTP health checks are wired for **`hello`** and **`worker`**, clarifies common misunderstandings (boot-time vs continuous probes, empty log files), and documents **`systemd.timer` + `Type=oneshot`** periodic probes shipped in the image (in addition to boot-time `ExecStartPost`).

## User identity and shared group `apps`

Static users **`hello`** and **`worker`** have primary groups of the same name and are **members of `apps`** for shared resources ([`hello.conf`](../../bootc/apps/hello/rootfs/usr/lib/sysusers.d/hello.conf), [`worker.conf`](../../bootc/apps/worker/rootfs/usr/lib/sysusers.d/worker.conf), [`apps.conf`](../../bootc/libs/common/rootfs/usr/lib/sysusers.d/apps.conf)). Paths such as `/var/lib/bootc-testboot/shared/env` are **`0750` `root:apps`** ([`testboot-common.conf`](../../bootc/libs/common/rootfs/usr/lib/tmpfiles.d/testboot-common.conf)); generated env files are `root:apps` `0640` from [`testboot-app-setup.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/testboot-app-setup.sh).

**Main app units** ([`hello.service`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello.service), [`worker.service`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker.service)) use `User=` / `Group=` matching the service account. With `User=` set, systemd initializes **supplementary groups from the user database** (including `apps`), so those processes can read shared `EnvironmentFile=` paths. **`hello-healthcheck.service`** / **`worker-healthcheck.service`** use the **same** `User=` / `Group=` so periodic logs match **LogsDirectory=** ownership under `/var/log/bootc-testboot/{hello,worker}/`. They do **not** load `EnvironmentFile=` from `shared/env`—only `curl` + logging—so they do not rely on `apps` for that unit’s job; keeping **`Group=hello`** / **`Group=worker`** (not `Group=apps`) stays aligned with the main service and log layout.

For the **full log layout** and systemd targets, see [009-observability-logs.md](009-observability-logs.md).

## 1. What the image does today

### 1.1 Side-by-side

| Item | Hello | Worker |
|------|-------|--------|
| Unit | [`hello.service`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello.service) | [`worker.service`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker.service) |
| Main process | `/usr/bin/hello` | `/usr/bin/worker` |
| `Type` | `simple` (long-running) | `simple` (long-running) |
| Health URL (loopback) | `http://127.0.0.1:8000/health` | Boot `ExecStartPost`: `http://127.0.0.1:8001/` (liveness). Readiness: `http://127.0.0.1:8001/health` (503 until Mongo+RabbitMQ+Valkey are up). |
| App log file | `/var/log/bootc-testboot/hello/hello.log` | `/var/log/bootc-testboot/worker/worker.log` |
| Health log file (boot `ExecStartPost`) | `/var/log/bootc-testboot/hello/healthcheck.log` | `/var/log/bootc-testboot/worker/healthcheck.log` |
| Periodic health log (timer) | `/var/log/bootc-testboot/hello/healthcheck-periodic.log` | `/var/log/bootc-testboot/worker/healthcheck-periodic.log` |
| Timer + oneshot units | [`hello-healthcheck.timer`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello-healthcheck.timer) / [`hello-healthcheck.service`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello-healthcheck.service) | [`worker-healthcheck.timer`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker-healthcheck.timer) / [`worker-healthcheck.service`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker-healthcheck.service) |
| Restart policy | `Restart=always` / `RestartSec=5` | Same |

### 1.2 `ExecStartPost` is a one-shot smoke check, not a loop

Both units call [`healthcheck.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/healthcheck.sh) via **`ExecStartPost`**. In systemd, that runs **once** after the main `ExecStart` process has been invoked successfully—it does **not** run on an interval while the service stays `active (running)`.

So:

- **You get a new healthcheck log line when the unit starts** (including after each restart).
- **Without the timer units**, you would not get periodic checks every minute while the process keeps running without restarting. **With** [`hello-healthcheck.timer`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello-healthcheck.timer) / [`worker-healthcheck.timer`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker-healthcheck.timer), [`healthcheck.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/healthcheck.sh) runs on a schedule and appends to `healthcheck-periodic.log` (see table above).

### 1.3 Shared script: `healthcheck.sh`

- Uses `curl` with optional per-attempt timeout, expected status (default `200`), and optional **retries** (`max_attempts`, `retry_delay_sec`) for startup races.
- When `LOG_FILE` is set (as in the units), messages go through [`log.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/log.sh) and append to that file **and** stderr (journal).

### 1.3.1 Interpreting HTTP `000` vs `503` (worker)

| Logged status | Meaning | What to check |
|---------------|---------|----------------|
| **HTTP 000** | `curl` could not connect (connection refused, no listener). The process is not accepting `127.0.0.1:8001` yet or `worker.service` is not running. | `systemctl status worker`, `/var/log/bootc-testboot/worker/worker.log`, `journalctl -u worker`. |
| **HTTP 503** | TCP succeeded; [`/health`](../../repos/worker/handlers.go) reports **degraded** until Mongo, RabbitMQ, and Valkey all pass the in-process checks. | Infra env files, shared secrets, service logs for Mongo/RabbitMQ/Valkey. |

Boot `ExecStartPost` on worker probes **`/`** (liveness). Periodic **`worker-healthcheck.service`** probes **`/health`** (readiness) with the same retry shape as boot: `healthcheck.sh … 5 200 30 1` (per-attempt timeout 5s, expect 200, up to 30 attempts, 1s between attempts).

### 1.4 If the smoke check fails

`healthcheck.sh` exits `1` when the HTTP status is not expected. Depending on systemd version and unit configuration, a failing **`ExecStartPost`** can mark the service activation as failed even though the main daemon may still be running. Treat journal lines for `healthcheck.sh` as the source of truth for that run; verify with `systemctl status` and `journalctl -u hello` / `journalctl -u worker`.

### 1.5 `Restart=always` vs “stuck but still running”

`Restart=always` restarts the service when the **main process exits**. It does **not** detect a hung process that never exits and still listens badly, unless your `/health` endpoint reflects liveness correctly and something external probes it.

---

## 2. Why `healthcheck.log` or `*.log` can be 0 bytes while rotated files are large

Typical pattern on long-lived VMs:

1. **logrotate** (or similar) runs daily and rotates `healthcheck.log` → `healthcheck.log-YYYYMMDD` (or similar).
2. A **new empty** `healthcheck.log` is created.
3. **`ExecStartPost` has not run again** since rotation (service did not restart), so nothing new is appended → current file stays **0 bytes** until the next start/restart.

Rotation for these paths is defined under `bootc/` — see [009-observability-logs.md](009-observability-logs.md) (`bootc-testboot`, `hello`, `worker` snippets). See also [004-testing-guide.md](004-testing-guide.md) for journal vs files and logrotate notes.

**tmpfiles.d** ensures log/state directories exist, e.g.:

- [`testboot-common.conf`](../../bootc/libs/common/rootfs/usr/lib/tmpfiles.d/testboot-common.conf) — base paths under `/var/log/bootc-testboot`
- [`hello.conf`](../../bootc/apps/hello/rootfs/usr/lib/tmpfiles.d/hello.conf) — comments on `StateDirectory`/`LogsDirectory`
- [`worker.conf`](../../bootc/apps/worker/rootfs/usr/lib/tmpfiles.d/worker.conf) — worker state/log dirs

---

## 3. Options matrix (documentation / architecture)

| Approach | Purpose | Pros | Cons |
|----------|---------|------|------|
| Document only | Avoid misunderstanding | No image change | No continuous signal |
| **`systemd.timer` + oneshot `.service`** | Periodic local HTTP probe, append logs | No Go changes; uses existing `healthcheck.sh` | Extra units; small steady load from `curl` |
| External monitoring (LB, Prometheus, uptime checker) | Alerts, SLOs | Centralized; works fleet-wide | Needs network path or agent; loopback-only apps need exporter or bind change |
| Conditional restart on failed health | Auto-recovery | Can clear bad states | Risk of restart loops; needs backoff/counters |

---

## 4. Deep dive: `systemd.timer` and `Type=oneshot` (complementary, not alternatives)

- **`Type=oneshot`** (on a **`.service`**): the service runs a short task and exits (e.g. one `curl` via `healthcheck.sh`).
- **`.timer`**: a separate unit that schedules **when** to start another unit (usually that oneshot service).

Long-running apps (`hello`, `worker`) stay **`Type=simple`**. Periodic health runs are a **second** service (oneshot), triggered by a timer—**not** a replacement for the main service.

### 4.1 Sketch (illustrative names)

- `hello-healthcheck.service` — `Type=oneshot`, `ExecStart=` calling `healthcheck.sh` with `LOG_FILE` pointing to e.g. `healthcheck-periodic.log` (recommended) or the same file as boot (then intermix boot + periodic lines).
- `hello-healthcheck.timer` — `OnUnitActiveSec=` or `OnCalendar=` to set interval; `Unit=hello-healthcheck.service`.

Repeat for worker (`8001`). Use `After=network-online.target` and ordering relative to `hello.service` / `worker.service` as needed so the port is listening before probes (or accept failures while dependencies start—document the choice).

### 4.2 Safety notes

- Use **`RandomizedDelaySec`** if many timers exist on one host.
- **Do not** chain `systemctl restart hello` inside the oneshot without a guard—risk of **restart storms**; design backoff separately if required.

---

## 5. Operational checklist

**After boot / restart:**

```bash
systemctl status hello worker
journalctl -u hello -u worker -b --no-pager
curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/health
curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8001/health
```

**If timer-based probes are added later:**

```bash
systemctl list-timers --all
systemctl status hello-healthcheck.timer   # example unit name
```

---

## 6. Implementation status

- **Shipped in image:** `hello-healthcheck.service` + `hello-healthcheck.timer`, `worker-healthcheck.service` + `worker-healthcheck.timer` (see [`Containerfile`](../../Containerfile): `systemctl enable …timer`). Boot-time smoke remains `ExecStartPost` → `healthcheck.log`; periodic runs use **`healthcheck-periodic.log`** per app.
- **Schedule (defaults):** first run `OnBootSec=` 45s (hello) / 50s (worker), then every `OnUnitActiveSec=1min` with `RandomizedDelaySec=15`. Tune by editing the `.timer` units in [`bootc/apps/hello/rootfs/…`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/) and [`bootc/apps/worker/rootfs/…`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/) and rebuilding.

## References

- [`hello.service`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello.service)
- [`hello-healthcheck.service`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello-healthcheck.service) / [`hello-healthcheck.timer`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello-healthcheck.timer)
- [`worker.service`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker.service)
- [`worker-healthcheck.service`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker-healthcheck.service) / [`worker-healthcheck.timer`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker-healthcheck.timer)
- [`healthcheck.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/healthcheck.sh)
- [systemd.exec(5)](https://www.freedesktop.org/software/systemd/man/systemd.exec.html) — `ExecStartPost`
- [systemd.timer(5)](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
