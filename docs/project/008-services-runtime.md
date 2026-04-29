# Services runtime: targets, identity, healthchecks, logs

This document is the **runtime contract** for every long-running service in bootc-testboot:

- systemd targets and startup ordering
- service user / group identity and shared `apps` group
- HTTP healthcheck pattern (`ExecStartPost` smoke + `.timer` periodic)
- log file layout and `logrotate` policy
- shared-env security model

Per-app reference (endpoints, env tiers, troubleshooting) lives in [009-apps-reference.md](009-apps-reference.md).

---

## 1. systemd targets (startup order)

| Target | Role |
|--------|------|
| [`testboot-infra.target`](../../bootc/libs/common/rootfs/usr/lib/systemd/system/testboot-infra.target) | Groups infrastructure daemons: `mongod`, `valkey`, `rabbitmq-server`, `nginx`. Orders after `network-online` and `mongodb-setup` (first-boot TLS/creds for MongoDB). |
| [`testboot-apps.target`](../../bootc/libs/common/rootfs/usr/lib/systemd/system/testboot-apps.target) | Groups **`hello`** and **`worker`**. Requires [`testboot-infra.target`](../../bootc/libs/common/rootfs/usr/lib/systemd/system/testboot-infra.target) and runs after [`testboot-app-setup.service`](../../bootc/libs/common/rootfs/usr/lib/systemd/system/testboot-app-setup.service) (shared env under `/var/lib/bootc-testboot/shared/env/`). |

Application units ([`hello.service`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello.service), [`worker.service`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker.service)) use **`PartOf=testboot-apps.target`** and **`WantedBy=testboot-apps.target`** so they are enabled with the target (not directly under `multi-user.target`).

**Operator commands:**

```bash
systemctl status testboot-infra.target testboot-apps.target
systemctl start testboot-apps.target    # starts infra first (dependency), then apps
systemctl stop testboot-apps.target     # stops hello + worker (PartOf)
```

Infra daemons keep running when you stop only `testboot-apps.target` (by design). To stop everything including databases, stop units explicitly: `systemctl stop mongod valkey rabbitmq-server nginx`.

---

## 2. User identity and shared group `apps`

Static users **`hello`** and **`worker`** have primary groups of the same name and are **members of `apps`** for shared resources ([`hello.conf`](../../bootc/apps/hello/rootfs/usr/lib/sysusers.d/hello.conf), [`worker.conf`](../../bootc/apps/worker/rootfs/usr/lib/sysusers.d/worker.conf), [`apps.conf`](../../bootc/libs/common/rootfs/usr/lib/sysusers.d/apps.conf)).

Paths such as `/var/lib/bootc-testboot/shared/env/` are **`0750` `root:apps`** ([`testboot-common.conf`](../../bootc/libs/common/rootfs/usr/lib/tmpfiles.d/testboot-common.conf)); generated env files are `root:apps` `0640` from [`testboot-app-setup.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/testboot-app-setup.sh).

Main app units use `User=` / `Group=` matching the service account. With `User=` set, systemd initializes **supplementary groups from the user database** (including `apps`), so those processes can read shared `EnvironmentFile=` paths. The companion **`*-healthcheck.service`** units use the **same** `User=` / `Group=` so periodic logs match `LogsDirectory=` ownership under `/var/log/bootc-testboot/{hello,worker}/`. They do **not** load shared env files (they only run `curl` + logging), so keeping `Group=hello` / `Group=worker` (not `Group=apps`) stays aligned with the main service and log layout.

---

## 3. Healthcheck pattern

### 3.1 Two probes per app

| Probe | Where | Runs | Log file |
|-------|-------|------|----------|
| **Boot smoke** | `ExecStartPost` on the main `.service` | Once after each (re)start | `/var/log/bootc-testboot/<app>/healthcheck.log` |
| **Periodic** | `.timer` → `Type=oneshot` `.service` | On schedule (default ~1min) | `/var/log/bootc-testboot/<app>/healthcheck-periodic.log` |

Both probes call the same shared script: [`healthcheck.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/healthcheck.sh).

### 3.2 Side-by-side: hello vs worker

| Item | Hello | Worker |
|------|-------|--------|
| Main unit | [`hello.service`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello.service) | [`worker.service`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker.service) |
| `Type` | `simple` | `simple` |
| Boot probe URL | `http://127.0.0.1:8000/health` | `http://127.0.0.1:8001/` (liveness) |
| Periodic probe URL | `http://127.0.0.1:8000/health` | `http://127.0.0.1:8001/health` (readiness — 503 until Mongo+RabbitMQ+Valkey are up) |
| Timer + oneshot | [`hello-healthcheck.timer`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello-healthcheck.timer) / [`hello-healthcheck.service`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello-healthcheck.service) | [`worker-healthcheck.timer`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker-healthcheck.timer) / [`worker-healthcheck.service`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker-healthcheck.service) |
| Restart policy | `Restart=always` / `RestartSec=5` | Same |

### 3.3 `ExecStartPost` is a one-shot smoke check, not a loop

In systemd, `ExecStartPost` runs **once** after the main `ExecStart` process has been invoked successfully — it does **not** run on an interval while the service stays `active (running)`.

So:

- A new `healthcheck.log` line appears **only when the unit (re)starts**.
- Without the `.timer` units you would not get periodic checks while the process keeps running. With them, [`healthcheck.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/healthcheck.sh) runs on a schedule and appends to `healthcheck-periodic.log`.

### 3.4 Shared script: `healthcheck.sh`

- Uses `curl` with optional per-attempt timeout, expected status (default `200`), and optional **retries** (`max_attempts`, `retry_delay_sec`) for startup races.
- When `LOG_FILE` is set (as in the units), messages go through [`log.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/log.sh) and append to that file **and** stderr (journal).

### 3.5 Interpreting HTTP `000` vs `503` (worker)

| Logged status | Meaning | What to check |
|---------------|---------|----------------|
| **HTTP 000** | `curl` could not connect (connection refused, no listener). The process is not accepting `127.0.0.1:8001` yet or `worker.service` is not running. | `systemctl status worker`, `/var/log/bootc-testboot/worker/worker.log`, `journalctl -u worker`. |
| **HTTP 503** | TCP succeeded; [`/health`](../../repos/worker/handlers.go) reports **degraded** until Mongo, RabbitMQ, and Valkey all pass the in-process checks. | Infra env files, shared secrets, service logs for Mongo/RabbitMQ/Valkey. |

Periodic **`worker-healthcheck.service`** probes `/health` with retry shape: `healthcheck.sh … 5 200 30 1` (per-attempt timeout 5s, expect 200, up to 30 attempts, 1s between attempts).

### 3.6 If the smoke check fails

`healthcheck.sh` exits `1` when the HTTP status is not expected. Depending on systemd version and unit configuration, a failing `ExecStartPost` can mark the service activation as failed even though the main daemon may still be running. Treat journal lines for `healthcheck.sh` as the source of truth for that run; verify with `systemctl status` and `journalctl -u hello` / `journalctl -u worker`.

### 3.7 `Restart=always` vs "stuck but still running"

`Restart=always` restarts the service when the **main process exits**. It does **not** detect a hung process that never exits and still listens badly, unless the `/health` endpoint reflects liveness correctly and something external probes it.

### 3.8 Timer schedule (defaults)

- **First run** `OnBootSec=` 45s (hello) / 50s (worker)
- **Then** every `OnUnitActiveSec=1min` with `RandomizedDelaySec=15`
- Tune by editing the `.timer` units in [`bootc/apps/hello/rootfs/…`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/) and [`bootc/apps/worker/rootfs/…`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/) and rebuilding.

### 3.9 Options matrix (when designing future probes)

| Approach | Purpose | Pros | Cons |
|----------|---------|------|------|
| Document only | Avoid misunderstanding | No image change | No continuous signal |
| **`systemd.timer` + oneshot `.service`** (current) | Periodic local HTTP probe, append logs | No Go changes; uses existing `healthcheck.sh` | Extra units; small steady load from `curl` |
| External monitoring (LB, Prometheus, uptime checker) | Alerts, SLOs | Centralized; works fleet-wide | Needs network path or agent; loopback-only apps need exporter or bind change |
| Conditional restart on failed health | Auto-recovery | Can clear bad states | Risk of restart loops; needs backoff/counters |

**Safety notes when extending:** use `RandomizedDelaySec` if many timers exist on one host; **do not** chain `systemctl restart <app>` inside a oneshot without a guard — risk of restart storms.

---

## 4. Log locations (canonical contract)

| Path | Content |
|------|---------|
| `/var/log/bootc-testboot/hello/hello.log` | Hello app |
| `/var/log/bootc-testboot/hello/healthcheck.log` | Boot-time smoke (`ExecStartPost`) |
| `/var/log/bootc-testboot/hello/healthcheck-periodic.log` | Timer-based HTTP checks |
| `/var/log/bootc-testboot/worker/worker.log` | Worker app |
| `/var/log/bootc-testboot/worker/healthcheck.log` | Boot smoke |
| `/var/log/bootc-testboot/worker/healthcheck-periodic.log` | Timer checks |
| `/var/log/bootc-testboot/app-setup.log` | [`testboot-app-setup`](../../bootc/libs/common/rootfs/usr/libexec/testboot/testboot-app-setup.sh) |
| `/var/log/mongodb/` | MongoDB setup/init |
| **Journal** | Always: `journalctl -u hello -u worker -b` |

**tmpfiles.d** ensures log/state directories exist:

- [`testboot-common.conf`](../../bootc/libs/common/rootfs/usr/lib/tmpfiles.d/testboot-common.conf) — base paths under `/var/log/bootc-testboot`
- [`hello.conf`](../../bootc/apps/hello/rootfs/usr/lib/tmpfiles.d/hello.conf), [`worker.conf`](../../bootc/apps/worker/rootfs/usr/lib/tmpfiles.d/worker.conf) — per-app state/log dirs

### 4.1 Why `*.log` can be 0 bytes while rotated files are large

Typical pattern on long-lived VMs:

1. **logrotate** runs daily and rotates `healthcheck.log` → `healthcheck.log-YYYYMMDD`.
2. A **new empty** `healthcheck.log` is created.
3. **`ExecStartPost` has not run again** since rotation (service did not restart), so nothing new is appended → current file stays **0 bytes** until the next start/restart.

The periodic `*-healthcheck-periodic.log` is unaffected because the timer keeps appending.

---

## 5. logrotate

Rotation is split so **logrotate** never sees the same path twice (a duplicate makes `logrotate.service` fail):

| Snippet | Paths | Notes |
|---------|--------|--------|
| [`etc/logrotate.d/bootc-testboot`](../../bootc/libs/common/rootfs/etc/logrotate.d/bootc-testboot) | `/var/log/bootc-testboot/*.log` | Top-level only (e.g. `app-setup.log`). **Daily**, `rotate 28` (~four weeks), `copytruncate`. Optional commented `maxsize` / `size` in file. |
| [`etc/logrotate.d/hello`](../../bootc/apps/hello/rootfs/etc/logrotate.d/hello) | `/var/log/bootc-testboot/hello/*.log` | `su hello hello`. Same daily / rotate / optional size caps. |
| [`etc/logrotate.d/worker`](../../bootc/apps/worker/rootfs/etc/logrotate.d/worker) | `/var/log/bootc-testboot/worker/*.log` | `su worker worker`. Same. |

**Journald** is not rotated by these snippets; rely on `journald.conf` / vendor defaults for persistent journal.

**Disk tuning:** `logrotate(8)` — `maxsize` rotates when a file exceeds the size but still respects the schedule; plain `size` ignores the time schedule (use one style). Uncomment examples in the snippets if logs grow faster than one day.

See also [004-testing-guide.md](004-testing-guide.md) for journal vs files notes during local testing.

---

## 6. Security: shared env on disk (Phase E)

Generated files under `/var/lib/bootc-testboot/shared/env/` are **`root:apps` `0640`**; directories are **`0750` `root:apps`**. Services run as `hello` / `worker` with supplementary group `apps` so they can read secrets **without** world-readable files. Rotate secrets by re-running setup flows and replacing overrides; for stronger host-bound secrets, consider `systemd-creds` (not wired in this image by default).

---

## 7. Operational checklist

**After boot / restart:**

```bash
systemctl status testboot-infra.target testboot-apps.target
systemctl status hello worker
journalctl -u hello -u worker -b --no-pager
curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/health
curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8001/health
```

**Timer-based probes:**

```bash
systemctl list-timers --all
systemctl status hello-healthcheck.timer worker-healthcheck.timer
```

---

## References

- [`hello.service`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/hello.service) / [`hello-healthcheck.{service,timer}`](../../bootc/apps/hello/rootfs/usr/lib/systemd/system/)
- [`worker.service`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/worker.service) / [`worker-healthcheck.{service,timer}`](../../bootc/apps/worker/rootfs/usr/lib/systemd/system/)
- [`healthcheck.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/healthcheck.sh)
- [`testboot-app-setup.sh`](../../bootc/libs/common/rootfs/usr/libexec/testboot/testboot-app-setup.sh)
- [009-apps-reference.md](009-apps-reference.md) — per-app endpoints, env tiers, troubleshooting
- [003-deploying-and-upgrading.md](003-deploying-and-upgrading.md) — upgrade and ops runbook
- [systemd.exec(5)](https://www.freedesktop.org/software/systemd/man/systemd.exec.html) — `ExecStartPost`
- [systemd.timer(5)](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
