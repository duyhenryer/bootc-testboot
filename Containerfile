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
ARG GIT_SHA=unknown
FROM ${BASE_IMAGE}:${BASE_DISTRO}-${BASE_IMAGE_VERSION}

# --- Rootfs Overlays (immutable configs, systemd units, tmpfiles, repo files) ---
# Must come BEFORE dnf install so MongoDB + RabbitMQ repo files are visible.
COPY bootc/libs/*/rootfs/ /
COPY bootc/apps/*/rootfs/ /
COPY bootc/services/*/rootfs/ /

# --- Import GPG keys for external repos (MongoDB 8.0 + RabbitMQ/Erlang) ---
RUN rpm --import https://pgp.mongodb.com/server-8.0.asc && \
    rpm --import https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc && \
    rpm --import https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key && \
    rpm --import https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key

# --- Middleware (version pinned per product release) ---
# RabbitMQ/Erlang: upstream only publishes x86_64 RPMs, skip on arm64.
RUN dnf install -y nginx redis mongodb-org-server && \
    if [ "$(uname -m)" = "x86_64" ]; then \
        dnf install -y erlang rabbitmq-server; \
    fi && \
    dnf clean all && \
    rm -rf /var/cache/{dnf,ldconfig} && \
    rm -rf /var/log/{dnf*,hawkey*,rhsm} /var/lib/dnf

# --- Pre-built app binaries (from output/bin/) ---
COPY output/bin/ /usr/bin/

# --- Immutable configs: symlink /etc -> /usr/share (read-only at runtime) ---
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf && \
    rm -rf /etc/nginx/conf.d && \
    ln -sf /usr/share/nginx/conf.d /etc/nginx/conf.d && \
    ln -sf /usr/share/mongodb/mongod.conf /etc/mongod.conf && \
    ln -sf /usr/share/redis/redis.conf /etc/redis/redis.conf && \
    if [ "$(uname -m)" = "x86_64" ]; then \
        mkdir -p /etc/rabbitmq && \
        ln -sf /usr/share/rabbitmq/rabbitmq.conf /etc/rabbitmq/rabbitmq.conf; \
    fi

# --- SELinux: allow nginx to proxy to upstream apps ---
RUN setsebool -P httpd_can_network_connect 1 || true

# --- Firewall rules ---
RUN firewall-offline-cmd --zone=public \
    --add-port=80/tcp --add-port=443/tcp --add-port=8080/tcp \
    --add-port=6379/tcp --add-port=27017/tcp && \
    if [ "$(uname -m)" = "x86_64" ]; then \
        firewall-offline-cmd --zone=public \
            --add-port=5672/tcp --add-port=15672/tcp; \
    fi

# --- Auto-enable all services that declare WantedBy= ---
RUN for svc in /usr/lib/systemd/system/*.service; do \
      if grep -q '^WantedBy=' "$svc" 2>/dev/null; then \
        systemctl enable "$(basename "$svc")" 2>/dev/null || true; \
      fi; \
    done

# --- Clean /var and /run artifacts from package install + overlay layer merges ---
RUN rm -f /var/log/mongodb/mongod.log && \
    rm -rf /var/lib/rhsm/productid.js /var/lib/rhsm/repo_server_val \
    /var/home/appuser/.bash* \
    /var/roothome/buildinfo \
    /run/cloud-init /run/mongodb /run/rhsm

# --- Validate ---
RUN bootc container lint

# --- Image metadata ---
ARG BASE_IMAGE
ARG BASE_DISTRO
ARG BASE_IMAGE_VERSION
ARG GIT_SHA
LABEL containers.bootc=1
LABEL org.opencontainers.image.source="https://github.com/duyhenryer/bootc-testboot"
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}:${BASE_DISTRO}-${BASE_IMAGE_VERSION}"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
