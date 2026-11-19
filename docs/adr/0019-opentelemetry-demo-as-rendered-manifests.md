# ADR-0019: The OpenTelemetry Demo is committed to the Sandbox as rendered manifests

- **Status:** Accepted
- **Date:** 2026-11-16

## Context

The OpenTelemetry Demo is distributed as a Helm chart, but the rendering path for PatchResources and Rollback patches plain manifest files at a Workload's `pagerless.dev/source-path`. Supporting Helm values would need a second rendering path that patches nested value paths, to be built, tested and secured for a single application.

## Decision

The Sandbox contains a trimmed subset of the OpenTelemetry Demo, limited to the services the Scenarios need, rendered once with `helm template` and committed as plain manifests. Each rendered Workload carries the `pagerless.dev/source-path` annotation like any other Sandbox Workload.

## Consequences

- Every Action uses the single plain-manifest rendering path.
- Upgrading the demo means re-rendering and committing the output, which is recorded as a Sandbox commit.

## Alternatives considered

- **Keep the Helm chart and patch values.** Closer to typical deployments, but it doubles the rendering surface for one application.
