# etcd fleet tooling: python3 TCP proxy + pinned multi-arch etcdctl.
# Built per-arch by .github/workflows/build-demo-tools.yml with
# --platform linux/${ARCH} --build-arg TARGETARCH=${ARCH} (amd64, arm64).
ARG ETCD_VERSION=3.5.21

FROM registry.access.redhat.com/ubi10/ubi-minimal:latest AS etcd-bin
ARG TARGETARCH
ARG ETCD_VERSION
RUN microdnf install -y tar gzip ca-certificates \
    && microdnf clean all \
    && curl -fsSL -o /tmp/etcd.tar.gz \
        "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-${TARGETARCH}.tar.gz" \
    && tar -xzf /tmp/etcd.tar.gz -C /tmp \
    && cp "/tmp/etcd-v${ETCD_VERSION}-linux-${TARGETARCH}/etcdctl" /usr/local/bin/etcdctl \
    && chmod +x /usr/local/bin/etcdctl \
    && etcdctl version \
    && rm -rf /tmp/etcd*

FROM registry.access.redhat.com/ubi10/ubi-minimal:latest
RUN microdnf install -y python3 \
    && microdnf clean all
COPY --from=etcd-bin /usr/local/bin/etcdctl /usr/local/bin/etcdctl
# coreutils (head/base64/seq for the loader value generation) and bash ship
# in ubi-minimal; Jobs override ENTRYPOINT with their own sh -c scripts.
USER 65534
ENTRYPOINT ["/bin/bash"]
