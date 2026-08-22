[Home](../README.md) > Airgapped Smoke Test

# Airgapped Smoke Test (CrashLoopBackOff Scenario)

Validate an existing Kubernaut v1.5.7 deployment on airgapped OCP 4.18+, AF +
Console enabled, using the [crashloop](../scenarios/crashloop/) scenario.

```bash
git clone https://github.com/jordigilh/kubernaut-demo-scenarios.git
cd kubernaut-demo-scenarios
```

## 1. Mirror the 2 scenario images

```bash
export DEST="artifactory.example.com/kubernaut"   # your registry path
skopeo login "${DEST%%/*}"

skopeo copy --all docker://quay.io/kubernaut-cicd/demo-http-server:1.0.0 \
  docker://${DEST}/demo-http-server:1.0.0

skopeo copy --all docker://quay.io/kubernaut-cicd/test-workflows/crashloop-rollback-job@sha256:d2488483a61afe4936c64fcd6ea5e807636b0c13d970fd4f8a25f9096f01e9d5 \
  docker://${DEST}/test-workflows/crashloop-rollback-job@sha256:d2488483a61afe4936c64fcd6ea5e807636b0c13d970fd4f8a25f9096f01e9d5
```

> Mirroring more scenarios later: `grep -h 'bundle:' deploy/remediation-workflows/*/*.yaml | awk '{print $2}' | sort -u`

## 2. Point the cluster at the mirror (skip if a rule already covers `quay.io/kubernaut-cicd`)

```yaml
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: kubernaut-cicd-mirror-tags
spec:
  imageTagMirrors:
    - source: quay.io/kubernaut-cicd
      mirrors: [artifactory.example.com/kubernaut]
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: kubernaut-cicd-mirror-digests
spec:
  imageDigestMirrors:
    - source: quay.io/kubernaut-cicd/test-workflows/crashloop-rollback-job
      mirrors: [artifactory.example.com/kubernaut/test-workflows/crashloop-rollback-job]
```

```bash
oc apply -f kubernaut-cicd-mirror.yaml
oc wait mcp/worker mcp/master --for=condition=Updated --timeout=20m
```

If Artifactory needs auth, link a pull secret into `demo-checkout` and `kubernaut-workflows`:

```bash
oc create secret docker-registry artifactory-pull-secret \
  --docker-server=artifactory.example.com --docker-username=<user> --docker-password=<token> \
  -n kubernaut-workflows
oc secrets link default artifactory-pull-secret --for=pull -n kubernaut-workflows
```

## 3. Seed the workflow catalog (only if missing)

```bash
kubectl get remediationworkflow -n kubernaut-system | grep crashloop-rollback-v1 || {
  kubectl apply -f deploy/action-types/rollback-deployment.yaml -n kubernaut-system
  kubectl apply -f deploy/remediation-workflows/crashloop/ -n kubernaut-system
}
```

## 4. Run it (Console-driven)

```bash
export PLATFORM=ocp
./scenarios/crashloop/run.sh --no-validate
```

Deploys the workload and injects the bad release, then exits immediately —
it does not wait for the alert, since this path doesn't need it.

In the Console chat, type:

```
investigate the alert in the demo-checkout namespace
```

**What to expect:**

| You should see | Meaning |
|---|---|
| A root-cause card within ~1-3 min | KA finished investigating; check it names `Deployment/worker` and a command-override / bad-release root cause |
| Phase label `Awaiting Approval` + a `crashloop-rollback-v1` workflow card | Correct workflow was selected; click **Approve** (production namespaces always require it) |
| Phase label `Verifying` | Rollback job ran, EM is confirming stabilization (~30-60s) |
| Phase label `Complete` | Remediated — total time ~3-5 min from the chat message |

**Signs it's not working, not just slow:**

| Symptom | Likely cause |
|---|---|
| No root-cause card after ~5 min, phase label never appears | AF/KA unreachable — `kubectl get pods -n kubernaut-system -l app=apifrontend` |
| Workflow card appears but `crashloop-rollback-v1` isn't offered | Catalog not seeded — redo Step 3 |
| Phase jumps straight to `Verifying`, no Approve button | Approval policy auto-approved for this run — expected on some policies, not a bug |
| Chat message sends but nothing happens at all | Console can't reach AF's MCP endpoint — check the AF route/service and browser console for connection errors |

## 5. Pass criteria

```bash
kubectl get pods -n demo-checkout                          # Running, 0 recent restarts
kubectl rollout history deployment/worker -n demo-checkout  # 2+ revisions
kubectl get rr -n kubernaut-system -o wide                   # Completed / Remediated
```

## Cleanup

```bash
./scenarios/crashloop/cleanup.sh
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `ImagePullBackOff` (scenario/workflow pods) | `oc get itms,idms`; `oc get mcp` is `Updated`; image actually mirrored |
| `WorkflowExecution` `Pending` | `crashloop-rollback-v1` not seeded (step 3); `kubectl get sa crashloop-rollback-v1-runner -n kubernaut-workflows` |
| Console chat never responds | `kubectl get pods -n kubernaut-system -l app=apifrontend`; check the AF route and browser console for connection errors |
| LLM errors | `kubectl logs -l app=kubernaut-agent -n kubernaut-system` |
