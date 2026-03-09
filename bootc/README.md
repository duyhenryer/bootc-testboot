# bootc/ Layer Architecture

This directory contains all bootc image layers: shared libraries, middleware services, and application deployments. Everything follows a **rootfs overlay** pattern -- files are placed in a directory tree mirroring `/` and copied into the container image at build time.

```
bootc/
├── libs/          # Shared utility scripts and common tmpfiles
│   └── common/
├── services/      # Middleware daemons (nginx, mongodb, redis, rabbitmq)
│   ├── mongodb/
│   ├── nginx/
│   ├── rabbitmq/
│   └── redis/
└── apps/          # User-facing applications
    └── hello/
```

---

## How Layers Are Applied

The main `Containerfile` copies each layer's rootfs into the image root:

```dockerfile
COPY bootc/libs/*/rootfs/ /
COPY bootc/apps/*/rootfs/ /
COPY bootc/services/*/rootfs/ /
```

Order matters: libs first (scripts available to all), then apps and services.

---

## Layer Roles

| Layer | Purpose | What It Contains |
|-------|---------|------------------|
| **libs/** | Shared utilities used by services and apps | Shell scripts in `/usr/libexec/testboot/`, common tmpfiles.d |
| **services/** | Middleware daemons installed via `dnf` | Configs in `/usr/share/`, systemd drop-in overrides, tmpfiles.d, sysusers.d, yum repos |
| **apps/** | Custom applications built from `repos/` | systemd units, nginx vhost configs, tmpfiles.d, binaries from `output/bin/` |

---

## File Placement Rules

All files go under `<component>/rootfs/` mirroring their final path in the image:

| Image Path | Purpose | Example |
|------------|---------|---------|
| `/usr/libexec/testboot/` | Shared shell scripts | `log.sh`, `gen-password.sh` |
| `/usr/share/<service>/` | Immutable configs (read-only at runtime) | `mongod.conf`, `redis.conf` |
| `/usr/lib/systemd/system/<unit>.d/override.conf` | systemd drop-in overrides | `mongod.service.d/override.conf` |
| `/usr/lib/systemd/system/<unit>.service` | Custom systemd units | `hello.service` |
| `/usr/lib/tmpfiles.d/` | Persistent `/var` directory definitions | `mongodb.conf`, `testboot-common.conf` |
| `/usr/lib/sysusers.d/` | User/group definitions for `bootc container lint` | `mongod.conf`, `rabbitmq.conf` |
| `/etc/yum.repos.d/` | External package repositories | `mongodb-org-8.0.repo` |
| `/usr/share/nginx/conf.d/` | nginx virtual host configs | `hello.conf` |

---

## Available Library Scripts

All scripts live in `/usr/libexec/testboot/` and are installed from `bootc/libs/common/rootfs/`.

| Script | Type | Description |
|--------|------|-------------|
| `log.sh` | sourced | Structured logging (`log_info`, `log_warn`, `log_error`). Writes to stderr (journald) + optional `$LOG_FILE`. |
| `gen-password.sh` | executable | Atomic random password generation. Idempotent -- skips if file exists. |
| `wait-for-service.sh` | executable | TCP readiness probe. Polls until a host:port is reachable or timeout. |
| `healthcheck.sh` | executable | HTTP health endpoint check. Returns exit 0/1 based on HTTP status code. |
| `render-env.sh` | executable | Config template renderer. Replaces `@@VAR@@` placeholders with environment values. |

### Usage Examples

```bash
# Source the logging library in any script
source /usr/libexec/testboot/log.sh
log_info "Starting database migration"

# Generate a password on first boot (idempotent)
/usr/libexec/testboot/gen-password.sh /var/lib/myapp/db-password 48

# Wait for MongoDB before starting the app
/usr/libexec/testboot/wait-for-service.sh 127.0.0.1 27017 60

# Verify the app is healthy after startup
/usr/libexec/testboot/healthcheck.sh http://127.0.0.1:8080/health 10

# Render a config template with runtime credentials
export DB_PASS=$(cat /var/lib/myapp/db-password)
/usr/libexec/testboot/render-env.sh /usr/share/myapp/config.tmpl /run/myapp/config.conf
```

---

## How to Extend

### Adding a New Utility Script

1. Create the script at `bootc/libs/common/rootfs/usr/libexec/testboot/<name>.sh`
2. Add `#!/bin/bash` shebang and `set -euo pipefail`
3. Source `log.sh` for consistent logging: `source /usr/libexec/testboot/log.sh`
4. Add a usage header comment block (see existing scripts for the pattern)
5. Make it executable: `chmod +x <name>.sh`
6. If the script needs persistent state, add entries to `testboot-common.conf` (tmpfiles.d)

**Template:**

```bash
#!/bin/bash
# One-line description of what this script does.
#
# Usage: my-script.sh <required-arg> [optional-arg]
#   required-arg: What it is
#   optional-arg: What it is (default: value)
#
# Example in a systemd unit:
#   ExecStartPre=/usr/libexec/testboot/my-script.sh /var/lib/myapp/data

set -euo pipefail
source /usr/libexec/testboot/log.sh

ARG="${1:?Usage: my-script.sh <required-arg>}"

# ... script logic ...

log_info "Done: $ARG"
```

### Adding a New Service (Middleware)

Create the directory skeleton:

```
bootc/services/<name>/
└── rootfs/
    ├── etc/yum.repos.d/<name>.repo          # if external RPM repo needed
    └── usr/
        ├── lib/
        │   ├── sysusers.d/<name>.conf        # user/group for bootc lint
        │   ├── systemd/system/<name>.service.d/
        │   │   └── override.conf             # systemd drop-in override
        │   └── tmpfiles.d/<name>.conf        # persistent /var dirs
        └── share/<name>/
            └── <name>.conf                   # immutable config
```

Then in the main `Containerfile`:
1. `dnf install -y <package>` in the middleware install step
2. `ln -sf /usr/share/<name>/<name>.conf /etc/<name>/<name>.conf` for the config symlink
3. Add firewall rules if the service listens on new ports
4. The auto-enable loop picks up services with `WantedBy=` automatically

**Checklist:**
- [ ] Config in `/usr/share/<name>/` (immutable at runtime)
- [ ] systemd override with `StateDirectory=` and `LogsDirectory=`
- [ ] `tmpfiles.d` for any `/var` directories the package creates
- [ ] `sysusers.d` if the package creates system users
- [ ] Wire `gen-password.sh` in `ExecStartPre=` if service needs credentials
- [ ] Wire `wait-for-service.sh` if service depends on another

### Adding a New App

Create the directory skeleton:

```
bootc/apps/<name>/
└── rootfs/
    └── usr/
        ├── lib/
        │   ├── systemd/system/<name>.service  # custom unit
        │   └── tmpfiles.d/<name>.conf         # if extra /var dirs needed
        └── share/nginx/conf.d/<name>.conf     # nginx vhost (if web-facing)
```

Then:
1. Add the app source under `repos/<name>/` (with `go.mod` for Go apps)
2. The `make apps` target auto-discovers and builds all Go apps to `output/bin/`
3. Add the binary name to `EXPECTED_BINS` in `Makefile` for smoke tests
4. Add the service name to `EXPECTED_SVCS` in `Makefile` for smoke tests

---

## Convention Checklist

- All scripts: `#!/bin/bash` + `set -euo pipefail`
- All scripts: `source /usr/libexec/testboot/log.sh` for structured logging
- All scripts: idempotent (safe to run multiple times)
- All scripts: atomic writes where applicable (`mktemp` + `mv`)
- All scripts: `chmod +x` in the source tree
- All configs: immutable source in `/usr/share/`, symlinked from `/etc/`
- All `/var` directories: declared in `tmpfiles.d`
- All service users: declared in `sysusers.d` for `bootc container lint`
- All services: `StateDirectory=` and `LogsDirectory=` in systemd units/overrides
