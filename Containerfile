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

# --- Middleware (Layer 2: version pinned per product) ---
RUN dnf install -y \
        nginx \
    && dnf clean all \
    && rm -rf /var/cache/{dnf,ldconfig}

# --- Pre-built app binaries (from output/bin/) ---
COPY output/bin/ /usr/bin/

# --- App Configurations (Rootfs Overlay) ---
COPY bootc/apps/*/rootfs/ /
COPY bootc/services/*/rootfs/ /

# --- nginx: immutability symlink ---
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf

# --- App firewall rules ---
RUN firewall-offline-cmd --zone=public \
    --add-port=80/tcp --add-port=443/tcp --add-port=8080/tcp

# --- Enable app services ---
RUN systemctl enable nginx hello

# --- Image metadata ---
LABEL containers.bootc=1
LABEL org.opencontainers.image.source="https://github.com/duyhenryer/bootc-testboot"

# --- Validate ---
# Linting should be done in CI, not during the build itself.
