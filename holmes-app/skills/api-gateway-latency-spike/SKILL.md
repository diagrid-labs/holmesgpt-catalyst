---
name: api-gateway-latency-spike
description: Diagnose api-gateway p99 latency spikes, SLO breaches, upstream timeouts, and HTTP 504 errors on the api-gateway service in the production Kubernetes cluster
---

## Goal

- **Primary Objective:** Diagnose latency-related incidents on the `api-gateway` service, specifically p99 latency exceeding the 2s SLO, downstream timeout errors, and HTTP 504 responses.
- **Scope:** The `api-gateway` deployment in the `production` namespace, its ArgoCD application `api-gateway`, the Grafana dashboard `api-gateway-overview`, and its immediate upstream dependencies (`auth-service`, backend services).
- **Agent Mandate:** Follow the workflow steps sequentially. Do not skip steps even if you believe you know the cause — each step contributes evidence that disambiguates between deployment-related, capacity-related, and upstream-cascade causes.
- **Expected Outcome:** Identify the root cause (recent bad deployment, capacity exhaustion, or upstream cascade), recommend a remediation, and provide evidence (latency breakdown, ArgoCD revision history, HPA status, upstream health) supporting the conclusion.

## Environment

In this cluster the `api-gateway` service is deployed as the **`api-gateway-nginx`** Deployment (an nginx stand-in for the real service). When running kubectl/argocd commands, substitute `api-gateway-nginx` for `api-gateway`. The Grafana dashboard name (`api-gateway-overview`) and the conceptual service name in the runbook stay as `api-gateway`.

## Workflow for api-gateway Latency Diagnosis

1. **Examine latency breakdown by upstream.**
   - Action: Query the Grafana dashboard `api-gateway-overview` for the p99 latency panel broken down by upstream service.
   - Parameters: dashboard name `api-gateway-overview`, time range last 30 minutes.
   - Expected Output: per-upstream p99 latency values.
   - Success/Failure Criteria: if a single upstream dominates the latency (>70% of total), branch to step 5. If latency is uniform across upstreams, continue to step 2.

2. **Check ArgoCD application health for recent deployments.**
   - Action: Retrieve sync status, health status, and revision history for the `api-gateway` ArgoCD application.
   - Parameters: app name `api-gateway`.
   - Expected Output: current sync status (Synced/OutOfSync), health status (Healthy/Degraded/Progressing), and revisions deployed in the last 24 hours.
   - Success/Failure Criteria: a `Progressing` or recently-changed revision (within 30 minutes of latency spike onset) is strong evidence of a bad deployment — branch to step 6 (rollback). If sync is healthy and last revision is older than 24h, continue to step 3.

3. **Check HPA status and pod scaling.**
   - Action: Retrieve the HorizontalPodAutoscaler status and current/desired replica counts for the `api-gateway` deployment.
   - Parameters: namespace `production`, deployment `api-gateway`.
   - Expected Output: current replicas, desired replicas, current CPU/memory utilization vs. target.
   - Success/Failure Criteria: if utilization is at or near the HPA target (≥90%) and desired replicas equals the HPA max, this indicates capacity exhaustion — branch to step 7 (scale).

4. **Inspect recent pod logs for errors.**
   - Action: Fetch the most recent 100 log lines from the api-gateway deployment.
   - Parameters: namespace `production`, deployment `api-gateway`, tail 100 lines.
   - Expected Output: error messages, stack traces, or warning patterns.
   - Success/Failure Criteria: repeated upstream connection errors or timeouts in logs corroborate the upstream cascade hypothesis (step 5). Repeated OOM/memory warnings corroborate the capacity hypothesis (step 7).

5. **Verify upstream service health.**
   - Action: Check the health of upstream services identified in step 1 (typically `auth-service` and backend services).
   - Parameters: ArgoCD apps `auth-service` and any backend apps, plus active Grafana alerts for those services.
   - Expected Output: sync/health status and any firing alerts.
   - Success/Failure Criteria: if an upstream is Degraded or has active alerts, the latency cascade originates upstream — investigation hands off to that service's owners or runbook.

## Synthesize Findings

- **Data Correlation:** Combine the latency breakdown (step 1), ArgoCD revision history (step 2), HPA status (step 3), pod logs (step 4), and upstream health (step 5) into a single causal narrative.
- **Pattern Recognition:**
  - Recent deployment (last 30 min) + degraded health + uniform latency across upstreams ⇒ **bad deployment**.
  - HPA at max + high CPU/memory + no deployment activity ⇒ **capacity exhaustion**.
  - Single dominant upstream in latency breakdown + that upstream degraded ⇒ **upstream cascade**.
  - None of the above and clean logs ⇒ collect a stack trace from a long-running request and escalate.
- **Prioritization Logic:** Bad deployment > upstream cascade > capacity exhaustion, ordered by ease of rollback. Bad deployments resolve fastest by reverting; capacity issues take longer to validate after scaling.
- **Evidence Requirements:** Cite the ArgoCD revision SHA (for deployment hypothesis), the HPA utilization numbers (for capacity), or the upstream Grafana alert names (for cascade).
- **Example Synthesis:** "Latency spike began at 14:23 UTC, coincident with ArgoCD sync of revision `abc123` for `api-gateway`. Health status is now Degraded. Pod logs show repeated startup probe failures. Most likely cause: bad deployment of revision `abc123`."

## Recommended Remediation Steps

- **Immediate (bad deployment):** Sync the `api-gateway` ArgoCD application to the previous revision. Verify pod rollout completes and the latency p99 returns below 2s.
- **Immediate (capacity exhaustion):** Increase HPA `maxReplicas` in the ArgoCD app manifest, sync, and confirm new replicas reach Ready state.
- **Immediate (upstream cascade):** Do not modify `api-gateway`. Hand off to the upstream service runbook (e.g., `auth-service-crashloopbackoff`) and monitor api-gateway latency recovery as upstream stabilizes.
- **Verification:** p99 latency on `api-gateway-overview` returns below 2s for ≥5 minutes; ArgoCD app reports Healthy; no firing alerts on dependent services.
- **Escalation:** If none of the patterns match and latency persists, escalate with: latency breakdown screenshot, ArgoCD revision log, HPA describe output, and 200+ lines of recent pod logs.
- **Post-Remediation:** Watch the api-gateway p99 latency panel for 30 minutes after remediation. Investigate whether the SLO needs adjustment if the spike was within expected variance.
