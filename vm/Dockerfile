# syntax=docker/dockerfile:1
# QEMU/KVM runtime for the dsh guest VM; the guest itself is provisioned by
# cloud-init on first boot (see vm/entrypoint.sh and vm/cloud-init/user-data).
# The build context must contain dist/npm/deepseek-ai-dsh-<version>.tgz next
# to vm/ — the upstream-release.yml docker job assembles both.
FROM node:24-bookworm-slim AS dsh-tree
ARG DSH_VERSION
COPY dist/npm/deepseek-ai-dsh-${DSH_VERSION}.tgz /tmp/dsh.tgz
# Global layout: /opt/dsh/bin/dsh launcher, package tree under
# /opt/dsh/lib/node_modules/@deepseek-ai/dsh. Dependency tarballs resolve
# from the public registry — upstream publishes the whole dsh family there.
RUN npm install --location=global --prefix /opt/dsh /tmp/dsh.tgz \
 && npm cache clean --force \
 && rm /tmp/dsh.tgz

FROM debian:bookworm-slim
ARG DSH_VERSION
ARG DSH_COMMIT
LABEL org.opencontainers.image.title="dsh-vm" \
      org.opencontainers.image.description="DeepSeek Harness web UI in an Ubuntu guest under QEMU/KVM" \
      org.opencontainers.image.version="${DSH_VERSION}" \
      org.opencontainers.image.revision="${DSH_COMMIT}"
RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils genisoimage curl ca-certificates socat \
      openssh-client \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /share/config /share/skills /keys /vm/disk

COPY --from=dsh-tree /opt/dsh /opt/dsh
COPY vm/entrypoint.sh /vm/entrypoint.sh
COPY vm/cloud-init/user-data /vm/user-data
COPY vm/cloud-init/meta-data /vm/meta-data
COPY vm/dsh.service /vm/dsh.service

WORKDIR /vm
VOLUME ["/vm/disk"]
ENTRYPOINT ["/bin/bash", "/vm/entrypoint.sh"]
