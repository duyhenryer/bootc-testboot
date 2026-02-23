# Operations Runbook

Quick reference for day-to-day operations on bootc-managed EC2 instances.

---

## 1. Upgrade OS (Production-Safe)

### Pre-download (business hours, safe to run anytime)

```bash
sudo bootc upgrade --download-only
```

This pulls the new image and stages it. The running system is **not affected**. The staged deployment will **not** apply on reboot until explicitly unlocked.

### Verify staged deployment

```bash
sudo bootc status --verbose
```

Look for `Download-only: yes` -- this confirms the update is staged but won't apply on reboot.

### Check for updates without side effects

```bash
sudo bootc upgrade --check
```

Only downloads metadata. Does not change the download-only state.

### Apply during maintenance window

**Option A**: Apply the specific version you downloaded (does not check for newer):

```bash
sudo bootc upgrade --from-downloaded --apply
```

System reboots immediately into the new deployment.

**Option B**: Check for newer updates first, then apply:

```bash
sudo bootc upgrade --apply
```

Pulls from image source to check for newer versions before applying.

### GOTCHA: Unexpected reboot

If the system reboots before you apply a download-only update, the staged deployment is **discarded**. However, the downloaded image data remains cached, so re-running `bootc upgrade --download-only` will be fast.

---

## 2. Rollback OS

```bash
sudo bootc rollback
sudo systemctl reboot
```

This swaps the bootloader ordering to the previous deployment. No download needed -- just a pointer swap.

**Time**: ~1-2 minutes (reboot time only).

> **WARNING**: `/var` is **NOT** rolled back. Database data, logs, and application state in `/var` survive the rollback. If the new version ran schema migrations, you must handle the database rollback separately.

### Verify after rollback

```bash
sudo bootc status
# Booted image should show the previous version
```

---

## 3. Debug on Immutable OS

### Temporary writable /usr

```bash
sudo bootc usr-overlay
```

Creates a temporary writable overlay on `/usr`. Changes are **not persistent** across reboot. Useful for quick debugging (e.g., installing a tool temporarily).

### Check local /etc modifications

```bash
sudo ostree admin config-diff
```

Shows files in `/etc` that differ from the image defaults. Includes metadata changes (uid, gid, xattrs).

### View deployment status

```bash
sudo bootc status --verbose
```

Shows:
- Booted deployment (current)
- Staged deployment (if any)
- Rollback deployment (previous)
- Download-only status

### View service logs

```bash
journalctl -u hello -n 100          # app logs
journalctl -u nginx -n 50           # nginx logs
systemctl status hello nginx        # service status
```

---

## 4. Handle /opt (Read-Only) Apps

When deployed, `/opt` is read-only. Software that writes to `/opt` needs one of these solutions:

### Solution 1: Symlinks to /var (best -- maximum immutability)

```dockerfile
# In Containerfile:
RUN mkdir -p /opt/myapp && \
    ln -sr /var/log/myapp /opt/myapp/logs && \
    ln -sr /var/lib/myapp /opt/myapp/data
```

### Solution 2: BindPaths in systemd unit

```ini
[Service]
ExecStart=/opt/myapp/bin/myapp
BindPaths=/var/log/myapp:/opt/myapp/logs
BindPaths=/var/lib/myapp:/opt/myapp/data
```

### Solution 3: ostree-state-overlay (easiest, but allows some drift)

```dockerfile
# In Containerfile:
RUN systemctl enable ostree-state-overlay@opt.service
```

Creates a persistent writable overlay on `/opt`. Changes survive reboots but are overwritten on updates.

| Solution | Immutability | Complexity | Persistence | Use when |
|----------|-------------|------------|-------------|----------|
| Symlinks | Maximum | Medium | Via /var | You control the app layout |
| BindPaths | High | Low | Via /var | App has fixed paths, launched by systemd |
| State overlay | Lower | Lowest | Yes (until update) | Legacy app, hard to modify |

---

## 5. Common Gotchas

| Gotcha | Details |
|--------|---------|
| `rpm-ostree install` breaks `bootc upgrade` | Never use rpm-ostree to install packages on a bootc host. All packages must go in the Containerfile. |
| Bootloader needs separate update | `bootc upgrade` does NOT update the bootloader. Run `sudo bootupctl update` separately. |
| `/var` from Containerfile = first boot only | Content you COPY into `/var` in the Containerfile only takes effect on first install. Use `tmpfiles.d` or `StateDirectory=` instead. |
| Staged download-only discarded on reboot | If you reboot before applying, the staged deployment is lost. Image data remains cached. |
| Cannot SSH and `dnf install` | `/usr` is read-only. All changes must go through the Containerfile and a new image build. Use `bootc usr-overlay` for temporary debugging only. |
| `/etc` 3-way merge conflicts | If both the image and local host modify the same file in `/etc`, the image version wins. Use drop-in directories to avoid this. |

---

## 6. Emergency Procedures

### Instance won't boot

Launch a new EC2 instance from the previous known-good AMI. The old AMI is still available in AWS.

### Bad update deployed to fleet

```bash
sudo bootc rollback
sudo systemctl reboot
```

Time: ~2 minutes per instance. Can be parallelized across fleet via SSM Run Command.

### Need to debug a live issue

```bash
# Temporary writable access (lost on reboot)
sudo bootc usr-overlay

# Now you can install debug tools
sudo dnf install -y strace tcpdump

# Debug the issue...

# Reboot to return to clean immutable state
sudo systemctl reboot
```

### Check what image is running

```bash
sudo bootc status
```

Shows the exact container image reference and digest for the booted deployment.

---

## Quick Reference

| Task | Command |
|------|---------|
| Check status | `sudo bootc status` |
| Pre-download update | `sudo bootc upgrade --download-only` |
| Apply update + reboot | `sudo bootc upgrade --from-downloaded --apply` |
| Rollback + reboot | `sudo bootc rollback && sudo systemctl reboot` |
| Temp writable /usr | `sudo bootc usr-overlay` |
| Check /etc drift | `sudo ostree admin config-diff` |
| Update bootloader | `sudo bootupctl update` |
| Health checks | `./scripts/verify-instance.sh` |
