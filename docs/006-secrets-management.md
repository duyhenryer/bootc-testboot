# Secrets Management

A deep-dive guide for DevOps teams managing secrets in bootc systems—registry authentication, credential helpers, cloud metadata, and systemd credentials.

**Source:** [bootc: Secrets (e.g. container pull secrets)](https://bootc-dev.github.io/bootc/building/secrets.html)

**Related:** [systemd: System and Service Credentials](https://systemd.io/CREDENTIALS/)

---

## Pull Secrets for Registry Auth

For bootc to pull images from a private registry, authentication must be in one of:

- `/etc/ostree/auth.json`
- `/run/ostree/auth.json`
- `/usr/lib/ostree/auth.json`

The path **differs from podman's default** (`$XDG_RUNTIME_DIR/containers/auth.json` or `~/.docker/config.json`). bootc does not read `/root` by default, so registry auth must be in one of the paths above.

---

## Syncing bootc and podman Credentials

See [containers-auth.json man page](https://github.com/containers/image/blob/main/docs/containers-auth.json.5.md). To keep bootc and podman in sync, use a tmpfiles.d fragment to symlink:

```
L+ /run/ostree/auth.json - - - - /run/user/0/containers/auth.json
```

Or after a manual login:

```bash
ln -s /run/user/0/containers/auth.json /run/ostree/auth.json
```

---

## Explicit Login

For automation or manual login, pass `--authfile`:

```bash
echo "$PASSWORD" | podman login --authfile /run/ostree/auth.json \
  -u someuser --password-stdin registry.example.com
```

Use `/run/ostree/auth.json` when credentials are derived at boot (e.g. from IMDS). Use `/etc/ostree/auth.json` for persistent machine-local credentials.

AWS ECR example (from [AWS docs](https://docs.aws.amazon.com/AmazonECR/latest/userguide/Podman.html)):

```bash
aws ecr get-login-password --region us-east-1 | \
  podman login --authfile /run/ostree/auth.json \
  -u AWS --password-stdin 123456789.dkr.ecr.us-east-1.amazonaws.com
```

---

## Credential Helpers (ECR, etc.)

For credential helpers (e.g. `ecr-login`), you must also create a **no-op auth file** with empty JSON `{}` at the pull secret location. The helper is invoked at runtime; the empty file satisfies bootc's expectation of an auth file.

Example registries config:

```json
{
  "credHelpers": {
    "123456789.dkr.ecr.ap-southeast-1.amazonaws.com": "ecr-login"
  }
}
```

Place this in `/etc/containers/auth.json` (for podman) and ensure `/etc/ostree/auth.json` or `/run/ostree/auth.json` contains `{}` when using credential helpers.

---

## Embedding Secrets in Images

Secrets can be embedded if the registry is protected and you accept the risk. Be cautious about exposure in image layers, CI logs, and caches.

**Bootstrap secrets pattern:** Embed a minimal bootstrap secret (e.g. cluster join token), then have a provisioning service or unit fetch and manage other secrets (SSH keys, certs) at runtime.

---

## Cloud Metadata Pattern

Most IaaS systems (AWS, GCP, Azure) expose a metadata server. Use cloud-init, Ignition, or afterburn to fetch bootstrap secrets at boot. The image stays generic; secrets are injected per instance.

Example flow:
1. Instance boots
2. cloud-init/Ignition fetches user-data from metadata server
3. User-data includes SSH keys, registry tokens, or bootstrap config
4. Secrets written to `/etc`, `/run`, or `/var` as appropriate

---

## Disk Image Embedding (bootc-image-builder)

When building disk images with bootc-image-builder, the config.toml can include initial users (passwords, SSH keys). These become machine-local state at first boot. See [doc 007](007-bootc-image-builder.md).

Rotating such secrets requires re-provisioning or a separate management process.

---

## Our ECR Pattern

For Amazon ECR:

1. **Use amazon-ecr-credential-helper** — fetches tokens via IMDS; no static tokens, no 12-hour expiry handling in your code
2. **Configure credHelpers** in `/etc/containers/auth.json`:
   ```json
   {"credHelpers":{"123456789.dkr.ecr.ap-southeast-1.amazonaws.com":"ecr-login"}}
   ```
3. **Provide no-op auth file** — create `/etc/ostree/auth.json` with `{}` so bootc finds an auth file; the helper does the real work

On EC2, the instance role provides ECR access. No long-lived tokens in the image.

---

## systemd Credentials

[systemd credentials](https://systemd.io/CREDENTIALS/) provide secure, per-service credential passing:

- Acquired at service activation, released at deactivation
- Immutable during service runtime
- Access restricted to the service user
- Can be encrypted (TPM2, `/var`-stored key)
- Placed in non-swappable memory (ramfs)

### LoadCredential

Load from disk or propagate from system credential:

```ini
[Service]
LoadCredential=foobar:/etc/myfoobarcredential.txt
Environment=FOOBARPATH=%d/foobar
```

The service receives `$CREDENTIALS_DIRECTORY` pointing to a directory containing the credential files.

### LoadCredentialEncrypted

For sensitive data, use encrypted credentials:

```ini
LoadCredentialEncrypted=foobar:/path/to/encrypted.cred
```

Encrypt with:

```bash
systemd-creds encrypt --name=foobar plaintext.txt ciphertext.cred
```

### Passing to systemd (PID 1)

Credentials can be passed to the whole system via:

- **Container manager:** `$CREDENTIALS_DIRECTORY` for systemd in container
- **qemu:** `-smbios type=11,value=io.systemd.credential:foo=bar` or `-fw_cfg name=opt/io.systemd.credentials/foo,string=bar`
- **Initrd:** Files in `/run/credentials/@initrd/` imported during initrd→host transition
- **UEFI:** systemd-stub with credentials in EFI partition

### Well-known credentials

- `passwd.hashed-password.root` / `passwd.plaintext-password.root` — root password for systemd-sysusers
- `firstboot.locale`, `firstboot.timezone` — firstboot settings
- `tmpfiles.extra` — tmpfiles.d lines (base64 for binary)

---

## Bootstrap Secret Lifecycle

1. **Day 0:** Bootstrap secret injected via cloud-init, disk image config, or installer
2. **First boot:** Provisioning service uses bootstrap secret to authenticate to cluster/API
3. **Day 2:** Service fetches and updates SSH keys, certs, registry tokens
4. **Updates:** bootstrap secret can be rotated via re-provisioning; runtime secrets via your management tooling

---

## Practical Patterns Summary

| Scenario | Approach |
|----------|----------|
| Private registry (ECR) | credHelpers + empty `{}` auth file |
| Private registry (static) | `podman login --authfile /run/ostree/auth.json` at boot |
| SSH keys | cloud-init, tmpfiles.d, or bootc-image-builder config |
| App secrets | systemd `LoadCredential=` or `LoadCredentialEncrypted=` |
| Bootstrap join | cloud metadata, disk image config, or installer |
| Sync podman + bootc | tmpfiles.d symlink `L+ /run/ostree/auth.json ...` |

---

## Summary Checklist

- [ ] Use `/etc/ostree/auth.json` or `/run/ostree/auth.json` for bootc pull secrets
- [ ] For credential helpers, provide empty `{}` auth file
- [ ] Prefer ECR credential helper over static tokens on AWS
- [ ] Use cloud-init/Ignition for instance-specific secrets
- [ ] Use systemd credentials for service-level secrets
- [ ] Avoid embedding long-lived secrets in images when possible
