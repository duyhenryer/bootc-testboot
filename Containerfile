# =============================================================================
# Application Image (Layer 2)
# =============================================================================
# Base image is pre-built with production tuning (make base).
# This layer adds: middleware + app binaries + systemd units + configs.
#
# Build:
#   make build BASE_DISTRO=centos-stream9
#   make build BASE_DISTRO=fedora-41
# =============================================================================
ARG BASE_IMAGE=ghcr.io/duyhenryer/bootc-testboot-base
ARG BASE_DISTRO=centos-stream9
ARG BASE_IMAGE_VERSION=latest
FROM ${BASE_IMAGE}:${BASE_DISTRO}-${BASE_IMAGE_VERSION}

# --- Middleware (version pinned per product release) ---
RUN dnf install -y \
        nginx \
    && dnf clean all \
    && rm -rf /var/cache/{dnf,ldconfig} \
    && rm -rf /var/log/{dnf*,hawkey*,rhsm} /var/lib/dnf

# --- Pre-built app binaries (from output/bin/) ---
COPY output/bin/ /usr/bin/

# --- Rootfs Overlays (immutable configs, systemd units, tmpfiles) ---
COPY bootc/libs/*/rootfs/ /
COPY bootc/apps/*/rootfs/ /
COPY bootc/services/*/rootfs/ /

# --- Immutable configs: symlink /etc -> /usr/share (read-only at runtime) ---
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf && \
    rm -rf /etc/nginx/conf.d && \
    ln -sf /usr/share/nginx/conf.d /etc/nginx/conf.d

# --- Firewall rules ---
RUN firewall-offline-cmd --zone=public \
    --add-port=80/tcp --add-port=443/tcp --add-port=8080/tcp

# --- Auto-enable all services that declare WantedBy= ---
RUN for svc in /usr/lib/systemd/system/*.service; do \
      if grep -q '^WantedBy=' "$svc" 2>/dev/null; then \
        systemctl enable "$(basename "$svc")" 2>/dev/null || true; \
      fi; \
    done

# --- Image metadata ---
LABEL containers.bootc=1
LABEL org.opencontainers.image.source="https://github.com/duyhenryer/bootc-testboot"
