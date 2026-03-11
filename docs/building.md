[Home](../README.md) > Building Workflow Images

# Building Workflow Images

Scenario workflow images are pre-built and hosted at `quay.io/kubernaut-cicd/test-workflows/`. You only need to rebuild if you're modifying a scenario's workflow logic.

## Build all workflows

```bash
./scripts/build-demo-workflows.sh --local
```

## Build a single scenario's workflow

```bash
./scripts/build-demo-workflows.sh --scenario stuck-rollout --local
```

The `--local` flag loads the image directly into the Kind cluster instead of pushing to a remote registry.
