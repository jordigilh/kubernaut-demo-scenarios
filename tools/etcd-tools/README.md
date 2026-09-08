# etcd fleet tooling for the etcd-defrag-forecast live-spoke mode.
#
# Single multi-arch image (linux/amd64 + linux/arm64, built by
# .github/workflows/build-demo-tools.yml) providing:
# - python3: runs the hostNetwork TCP metrics proxy (fleet/live/proxy.yaml)
# - etcdctl (pinned release, arch-matched at build time): the loader and
#   defrag Jobs (fleet/loader-job.yaml, fleet/defrag-job.yaml)
#
# Rationale: registry.k8s.io/etcd is shell-less, quay.io/coreos/etcd is
# amd64-only (crashes under emulation on arm64 hosts), bitnami/etcd
# publishes no resolvable pinned minor tag, and installing etcd-client via
# apt at Job runtime is fragile. Baking the client in at build time keeps
# the Jobs hermetic. UBI base follows the other tools/ images.
#
# Versioned via VERSION (read by CI -> quay.io/kubernaut-cicd/etcd-tools).
# Bump it whenever this Dockerfile changes so spokes pick up the new image.
