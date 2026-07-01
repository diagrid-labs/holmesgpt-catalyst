---
name: checkout-api-imagepullbackoff
description: Diagnose checkout-api pods that never start — ImagePullBackOff / ErrImagePull, "image not found" / "manifest unknown", pods stuck Pending or PodInitializing, a checkout-api deployment that won't roll out after a release
---

## Goal

- **Primary Objective:** Determine why the `checkout-api` pods never become Ready and pinpoint the exact image reference that cannot be pulled.
- **Scope:** The `checkout-api` deployment in the `production` namespace and its ArgoCD application `checkout-api`.
- **Agent Mandate:** Execute the workflow in order. The dominant, persistent failure is the image pull — do not get distracted by transient warnings (e.g. a one-off volume/secret-mount timeout at pod creation) that resolve on their own.
- **Expected Outcome:** Name the unresolvable image (repository + tag), state that the tag does not exist in the registry, identify the deploy/revision that introduced it, and recommend correcting the tag (or rolling back to the last good revision).

## Environment

In this cluster `checkout-api` is deployed as the **`checkout-api-nginx`** Deployment (an nginx stand-in for the real service). When running kubectl/argocd commands, substitute `checkout-api-nginx`. The Helm chart also defines an **init container** that uses the **same image**, so an unpullable image stalls the pod at `PodInitializing` before the main container is ever reached — check init-container status, not just the main container.

## Workflow for checkout-api Start-up Failure

1. **Get pod status and the waiting reason (init AND main containers).**
   - Action: List the `checkout-api` pods and read `status.initContainerStatuses[*]` and `status.containerStatuses[*]` waiting reasons/messages.
   - Parameters: namespace `production`, selector `app.kubernetes.io/instance=checkout-api`.
   - Expected Output: a waiting reason of `ImagePullBackOff` or `ErrImagePull` on the init (and main) container, with a message naming the image.
   - Success/Failure Criteria: `ImagePullBackOff`/`ErrImagePull` → this is an image problem, go to step 2. `CrashLoopBackOff`/`OOMKilled` → wrong runbook (this is the crash/OOM scenario). `Pending` with no image error → check scheduling (step 4).

2. **Read the pull error from the pod events.**
   - Action: Describe the pod and read the `Failed`/`FailedToPull` warning events.
   - Parameters: the failing pod name, namespace `production`.
   - Expected Output: an event like `Failed to pull image "<repo>:<tag>": ... not found` / `manifest unknown`.
   - Success/Failure Criteria: a `not found` / `manifest unknown` error confirms the **tag does not exist** in the registry → step 3. `unauthorized` / `pull access denied` instead points at registry credentials, not a bad tag.

3. **Identify the exact image reference and confirm it's the only fault.**
   - Action: Read `spec.containers[*].image` and `spec.initContainers[*].image` from the pod/deployment.
   - Parameters: deployment `checkout-api-nginx`, namespace `production`.
   - Expected Output: the full `registry/repository:tag`. Note the tag (e.g. a non-semver / clearly-wrong value).
   - Success/Failure Criteria: every container references the same unpullable tag → the deployment was rolled out with a bad image tag.

4. **Tie it to the deployment that introduced it.**
   - Action: Check the `checkout-api` ArgoCD application's health/sync status and the most recent revision/parameters.
   - Parameters: app name `checkout-api`.
   - Expected Output: `Degraded`/`Progressing` health, and the `image.tag` (or equivalent) parameter set to the bad value.
   - Success/Failure Criteria: the bad tag is present in the synced revision → confirmed root cause: a deploy set an image tag that doesn't exist.

## Remediation

- State the root cause plainly: the `checkout-api` deployment references `**<repo>:<bad-tag>**`, which does not exist in the registry, so every pod (init container first) stays in `ImagePullBackOff` and never becomes Ready.
- Recommend: correct the image tag to a published version (or roll back the ArgoCD app to the last Healthy revision). No node, resource, or application-code change is involved.
