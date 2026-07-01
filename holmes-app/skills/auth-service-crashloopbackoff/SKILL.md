---
name: auth-service-crashloopbackoff
description: Diagnose auth-service pods entering CrashLoopBackOff, OOMKilled events, repeated pod restarts, and 401 authentication errors cascading across dependent services
---

## Goal

- **Primary Objective:** Diagnose CrashLoopBackOff and OOMKilled incidents on the `auth-service` deployment, including cascading 401 errors observed on dependent services.
- **Scope:** The `auth-service` deployment in the `production` namespace, its ArgoCD application `auth-service`, the Grafana dashboard `auth-service-overview`, and downstream services that depend on it for authentication.
- **Agent Mandate:** Execute the workflow in order. Do not roll back without first inspecting logs — a misleading recent deployment may not be the actual cause if a ConfigMap or Secret was the change vector.
- **Expected Outcome:** Identify whether the crash is caused by an out-of-memory condition, a configuration/secret change, or application code from a bad deployment. Recommend a remediation backed by log evidence and a rollback or limit-adjustment plan.

## Environment

In this cluster the `auth-service` is deployed as the **`auth-service-nginx`** Deployment (an nginx stand-in for the real service). When running kubectl/argocd commands, substitute `auth-service-nginx` for `auth-service`. The Grafana dashboard name (`auth-service-overview`) and the conceptual service name in the runbook stay as `auth-service`.

## Workflow for auth-service Crash Diagnosis

1. **Check ArgoCD application status and recent revisions.**
   - Action: Retrieve sync status, health status, and the last 5 revisions deployed for the `auth-service` ArgoCD application.
   - Parameters: app name `auth-service`.
   - Expected Output: sync status, health status, revision SHAs and timestamps.
   - Success/Failure Criteria: `Degraded` health with a recently-applied revision is a strong deployment-related signal — continue to step 2. If the last revision is older than 24h, the cause is unlikely to be code — branch to step 3.

2. **Inspect logs from the previous container instance.**
   - Action: Fetch the previous container's logs (the one that crashed), not the current one.
   - Parameters: namespace `production`, deployment `auth-service`, `--previous` flag, full log dump.
   - Expected Output: stack traces, panics, signal-induced exits, or OOM evidence in the final lines.
   - Success/Failure Criteria:
     - Stack trace pointing to a code path → bad code deployment (step 6).
     - Log lines mentioning "killed", exit code 137, or no orderly shutdown → likely OOM (step 3).
     - Configuration parse error or missing-key error → configuration change (step 4).

3. **Check the memory usage trend (Prometheus).**
   - Action: Use the `prometheus` toolset to query pod memory over the last hour — e.g. `container_memory_working_set_bytes{namespace="production", pod=~"auth-service-nginx.*"}` as a range query — and compare against the container's `resources.limits.memory`.
   - Note: query metrics through the **`prometheus`** toolset (the authoritative source). Grafana just visualizes this same data; if the `grafana/dashboards` toolset is enabled you may also pull up the `auth-service-overview` dashboard for a visual, but do not block on Grafana access.
   - Expected Output: memory trend per pod, especially the values immediately before each restart.
   - Success/Failure Criteria: a sawtooth pattern (memory climbs to the limit, then drops as the pod restarts) confirms OOMKilled. Flat memory with sudden crashes points back to code or config (step 4).

4. **Examine recent ConfigMap changes.**
   - Action: Inspect the ArgoCD diff view for the `auth-service` app, focusing on ConfigMap resources changed in the last 24 hours.
   - Parameters: app name `auth-service`, resource kind `ConfigMap`.
   - Note: **Secrets are intentionally out of scope** — the investigator's RBAC excludes `secrets` by design (it must never read credential values), so do not attempt to read Secrets; a permissions error there is expected, not a finding. Use the ArgoCD diff to detect that a Secret *changed* (name/revision) without reading its contents.
   - Expected Output: any modified keys/values in ConfigMaps bound to the deployment.
   - Success/Failure Criteria: a config change correlated with the first crash time strongly suggests configuration as the cause — branch to step 6 (rollback) with a focus on the changed object.

5. **Check pod events and resource limits.**
   - Action: Retrieve recent Kubernetes events on the pods and the deployment's resource limits.
   - Parameters: namespace `production`, deployment `auth-service`.
   - Expected Output: events such as `BackOff`, `OOMKilled`, `FailedScheduling`, and the deployment spec's `resources.limits.memory`.
   - Success/Failure Criteria: explicit `OOMKilled` events confirm step 3's hypothesis. `FailedScheduling` indicates a cluster-level capacity issue requiring different escalation.

6. **(Verification only) Identify the last-known-good revision.**
   - Action: From the ArgoCD revision history, identify the most recent revision where the app was Healthy.
   - Parameters: ArgoCD app `auth-service`.
   - Expected Output: a target revision SHA for rollback.
   - Success/Failure Criteria: if no Healthy revision exists in the recent history, escalate — rolling back further is risky without a known-good baseline.

## Synthesize Findings

- **Data Correlation:** Combine ArgoCD revision history (step 1), the previous container's logs (step 2), the Grafana memory trend (step 3), recent config changes (step 4), and pod events (step 5).
- **Pattern Recognition:**
  - Sawtooth memory + exit 137 + `OOMKilled` events ⇒ **memory limit too low or memory leak in recent code**.
  - Stack trace in previous logs + recent revision deployed ⇒ **bad code deployment**.
  - Config diff at exact crash time + parse/missing-key error in logs ⇒ **bad configuration**.
  - All three look clean ⇒ check cluster-level health (node memory pressure, image pull issues).
- **Prioritization Logic:** Bad config rollback > bad code rollback > memory limit increase. Config rollbacks are cheapest; memory limit increases require care to avoid pushing the same problem to a different pod.
- **Evidence Requirements:** Quote the exit code, the offending log line, the exact memory ceiling reached, or the changed ConfigMap key in the synthesis.
- **Example Synthesis:** "Previous container logs show exit code 137 with no orderly shutdown. Memory dashboard shows pods reaching the 256Mi limit just before each restart. No code or config changes in the last 7 days. Most likely cause: insufficient memory limit for current load."

## Recommended Remediation Steps

- **Immediate (OOM):** Increase the memory limit in the ArgoCD app manifest (typically doubling: 256Mi → 512Mi as a starting point) and sync. Watch the memory dashboard to confirm the new ceiling holds.
- **Immediate (bad code):** Sync the `auth-service` ArgoCD application to the last Healthy revision identified in step 6. Watch `kubectl rollout status deploy/auth-service -n production` until complete.
- **Immediate (bad config):** Revert the offending ConfigMap or Secret via ArgoCD and sync. If the change was intentional, fix the config and re-deploy.
- **Verification:** `kubectl rollout status deploy/auth-service -n production` reports successful rollout; pod restart count stops increasing; the cascading 401 alerts on dependent services clear within 5 minutes.
- **Escalation:** If neither rollback nor limit-increase resolves the crashes after 15 minutes, escalate with: ArgoCD app history, previous-container logs, memory dashboard screenshots, recent ConfigMap/Secret diffs, and pod event list.
- **Post-Remediation:** Monitor `auth-service-overview` memory trends and pod restart counts for 1 hour. If the cause was an OOM, schedule a follow-up to investigate memory growth patterns or possible leaks rather than relying solely on the increased limit.
