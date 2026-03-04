# Production Upgrade Scenarios

This document explains what happens to your system when you release a new version to a customer. It covers the **immutable config strategy**, upgrade behavior for each filesystem zone, and how to safely handle stateful services like MongoDB.

> **Pre-requisite reading:** [003-filesystem-layout.md](../bootc/003-filesystem-layout.md) -- you must understand `/usr`, `/etc`, and `/var` before reading this document.

---

## 1. Immutable Config Strategy

### The Problem

bootc uses a **3-way merge** for `/etc` during upgrades. If a customer edits a config file in `/etc`, the merge can conflict with your new version. This means:

- You cannot guarantee the config is correct after upgrade
- Customer edits can silently break services
- Debugging config issues on customer machines is painful

### Our Solution: All Configs in `/usr` (Read-Only)

We put **every config file** in `/usr/share/<service>/` and create symlinks from `/etc/` to point there:

```
/etc/nginx/nginx.conf  --->  /usr/share/nginx/nginx.conf  (read-only)
/etc/nginx/conf.d/     --->  /usr/share/nginx/conf.d/     (read-only)
/etc/mongod.conf       --->  /usr/share/mongodb/mongod.conf (read-only)
/etc/redis/redis.conf  --->  /usr/share/redis/redis.conf  (read-only)
```

**Why this works:**

- `/usr` is **read-only** at runtime -- customer cannot edit configs
- On upgrade, `/usr` is **fully replaced** -- new configs are atomically applied
- No merge conflicts, no drift, no surprises
- Customer just starts the VM and uses it

### How It Looks in the Containerfile

```dockerfile
# 1. Install the package (puts default config in /etc)
RUN dnf install -y nginx

# 2. Our custom config is in /usr/share/ (from rootfs overlay)
COPY bootc/services/nginx/rootfs/ /

# 3. Replace /etc config with symlink to /usr/share (immutable)
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf && \
    rm -rf /etc/nginx/conf.d && \
    ln -sf /usr/share/nginx/conf.d /etc/nginx/conf.d
```

### The Rootfs Overlay Pattern

Every service follows the same structure:

```
bootc/services/<service>/rootfs/
  usr/share/<service>/<config-file>          # immutable config
  usr/lib/systemd/system/<service>.service.d/override.conf  # systemd tweaks
  usr/lib/tmpfiles.d/<service>.conf          # /var directories
```

---

## 2. What Happens During `bootc upgrade`

When a customer runs `bootc upgrade` (or it runs automatically), here is exactly what happens to each part of the filesystem:

### `/usr` -- Fully Replaced

Everything in `/usr` is atomically swapped to the new image version:

| What | Example | Behavior |
|------|---------|----------|
| App binaries | `/usr/bin/hello`, `/usr/bin/app-api` | Old removed, new installed |
| Configs | `/usr/share/nginx/nginx.conf` | Replaced with new version |
| systemd units | `/usr/lib/systemd/system/hello.service` | Replaced with new version |
| tmpfiles.d | `/usr/lib/tmpfiles.d/mongodb.conf` | Replaced with new version |
| Libraries | `/usr/libexec/bootc-poc/*.sh` | Replaced with new version |

This is the core value: **one upgrade replaces all code, all configs, all units atomically**.

### `/etc` -- 3-Way Merge (but we avoid it)

Because all our configs are symlinks pointing to `/usr/share/`, the merge has nothing to conflict with. The symlinks themselves are simple and stable.

The only files in `/etc` that the customer's system might modify are:
- `/etc/machine-id` (auto-generated, unique per machine)
- `/etc/hostname` (set by cloud-init)
- SSH host keys (generated on first boot)

These are all machine-specific and merge safely.

### `/var` -- Untouched

**Nothing in `/var` is changed by the upgrade.** This is critical:

| Data | Location | Survives upgrade? | Survives rollback? |
|------|----------|-------------------|-------------------|
| MongoDB data | `/var/lib/mongodb/` | Yes | Yes |
| Redis data | `/var/lib/redis/` | Yes | Yes |
| RabbitMQ data | `/var/lib/rabbitmq/` | Yes | Yes |
| App state | `/var/lib/hello/` | Yes | Yes |
| All logs | `/var/log/*/` | Yes | Yes |
| SSH host keys | `/var/home/`, cloud-init state | Yes | Yes |

---

## 3. Release Scenarios

### Scenario A: Add a New App

**You built a new service `app-worker` and want to add it to the next release.**

What you do:
1. Add source code: `repos/app-worker/`
2. Add rootfs overlay: `bootc/apps/app-worker/rootfs/usr/lib/systemd/system/app-worker.service`
3. The Containerfile auto-discovers it (via `COPY bootc/apps/*/rootfs/ /` and the auto-enable loop)

What happens on customer upgrade:
- `/usr/bin/app-worker` appears (new binary)
- `/usr/lib/systemd/system/app-worker.service` appears (new unit)
- systemd starts it on next boot
- `/var/lib/app-worker/` is created by `StateDirectory=` on first start

**No manual steps needed on customer side.**

### Scenario B: Remove an App

**You want to remove the `old-reporter` service from the next release.**

What you do:
1. Remove `repos/old-reporter/` and `bootc/apps/old-reporter/`
2. The binary and service file are no longer in the image

What happens on customer upgrade:
- `/usr/bin/old-reporter` disappears (binary removed)
- `/usr/lib/systemd/system/old-reporter.service` disappears (unit removed)
- systemd no longer starts it
- `/var/lib/old-reporter/` **still exists** (orphan data in `/var`)

**Orphan data cleanup:** If you want to remove `/var/lib/old-reporter/`, add a one-time cleanup script:

```ini
# In a service file that runs once after upgrade
[Service]
Type=oneshot
ExecStart=/bin/rm -rf /var/lib/old-reporter
RemainAfterExit=yes
```

Or document that the customer can manually remove it: `rm -rf /var/lib/old-reporter`.

### Scenario C: Update a Config

**You changed the Redis `maxmemory` from 256mb to 512mb.**

What you do:
1. Edit `bootc/services/redis/rootfs/usr/share/redis/redis.conf`
2. Build and release

What happens on customer upgrade:
- `/usr/share/redis/redis.conf` is replaced (new maxmemory value)
- `/etc/redis/redis.conf` symlink still points to it
- Redis reads the new config on next restart
- No merge conflicts, no customer intervention

### Scenario D: MongoDB Schema Migration

**Your app v2 needs a new MongoDB collection or index.**

This is the one scenario that requires application-level handling, because `/var/lib/mongodb/` is never touched by the upgrade. The database schema must be migrated by your app.

**Recommended pattern:** Use `ExecStartPre=` in the app's systemd unit:

```ini
[Service]
ExecStartPre=/usr/bin/app-api --migrate
ExecStart=/usr/bin/app-api --serve
```

The `--migrate` command should:
1. Check the current schema version (e.g., a `_schema_version` collection)
2. Apply any pending migrations
3. Exit with 0 on success

**Important:** Migrations must be **forward-compatible**. If v2 adds a new index, v1 should still work with that index present (in case of rollback).

### Scenario E: New `/var` Directory Needed

**Your new service needs `/var/lib/newservice/data/`.**

What you do:
1. Add `bootc/services/newservice/rootfs/usr/lib/tmpfiles.d/newservice.conf`:
   ```
   d /var/lib/newservice/data 0755 newservice newservice -
   ```
2. Or use `StateDirectory=newservice` in the systemd unit (auto-creates `/var/lib/newservice`)

What happens on customer upgrade:
- The new tmpfiles.d entry is in `/usr` (replaced)
- On first boot after upgrade, `systemd-tmpfiles --create` creates the directory
- The service starts and finds its directory ready

---

## 4. Partition Planning

The `builder/*/config.toml` defines disk partitions for the generated VM images.

### Current Layout (POC)

```toml
[[customizations.filesystem]]
mountpoint = "/"
minsize = "10 GiB"

[[customizations.filesystem]]
mountpoint = "/var/data"
minsize = "5 GiB"
```

### Production Recommendations

For production with MongoDB and other stateful services, consider separating data partitions:

```toml
[[customizations.filesystem]]
mountpoint = "/"
minsize = "20 GiB"

[[customizations.filesystem]]
mountpoint = "/var/lib/mongodb"
minsize = "50 GiB"

[[customizations.filesystem]]
mountpoint = "/var/log"
minsize = "10 GiB"
```

**Why separate partitions?**
- MongoDB data grows independently -- a full data disk should not prevent OS from booting
- Log partition prevents log flooding from filling the root
- Easier to resize individual partitions per customer needs

---

## 5. Rollback (Brief)

Rollback is rare in our workflow because we test thoroughly before release. But here is what happens:

`bootc rollback` swaps `/usr` back to the previous image version. `/var` is **untouched**.

| Zone | On rollback |
|------|------------|
| `/usr` (binaries, configs, units) | Swapped to previous version |
| `/etc` (symlinks) | Symlinks still point to `/usr/share/` which is now the old version |
| `/var` (data, logs) | Unchanged -- MongoDB data, Redis data, all logs remain |

**The one risk:** If v2 ran a database migration (e.g., added a new MongoDB collection), rolling back to v1 means v1's code sees the v2 schema. This is why migrations should be forward-compatible.

---

## Quick Reference

| Question | Answer |
|----------|--------|
| Can customer edit configs? | No -- configs are in `/usr` (read-only) |
| What happens to configs on upgrade? | Replaced atomically (no merge) |
| What happens to data on upgrade? | Untouched (`/var` is never modified) |
| What happens to data on rollback? | Untouched (`/var` is never rolled back) |
| How to add a new app? | Add to `repos/` + `bootc/apps/`, auto-discovered |
| How to remove an app? | Remove from `repos/` + `bootc/apps/`, orphan `/var` data stays |
| How to handle DB migration? | `ExecStartPre=` in systemd unit |
| How to add new `/var` dirs? | `tmpfiles.d` or `StateDirectory=` |
