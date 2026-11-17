# pagerless-sandbox

Demo Workloads for [Pagerless](https://github.com/a-hagi613/pagerless). Argo CD deploys the manifests in this repository, Scenarios inject failures into it as commits, and Pagerless remediates failures by opening pull requests against it.

This repository is a GitHub template. Create your own copy, then point Pagerless at it with `SANDBOX_URL` in the `.env` file that `make up` writes.

### Setting up your copy

Repository settings and branch protection are not copied with a template, so configure your copy after creating it:

1. Enable auto-merge in the repository settings (Settings, General, Pull Requests).
2. Add a branch protection rule for `main` that requires the `kubeconform` status check. Pagerless opens pull requests with auto-merge, so this rule is what makes them wait for validation.
3. Allow force pushes for `main` if you want `make reset` to work without an administrator bypass.
4. Create the `known-good` tag on the commit in which every Workload is healthy.

## The demo

The Workloads are a trimmed [OpenTelemetry Demo](https://opentelemetry.io/docs/demo/) 3.1.0: frontend, frontend-proxy, cart with its valkey store, checkout, payment, product-catalog with its astronomy database, email, flagd, shipping, quote, currency, kafka, and the load generator that drives them. Their telemetry goes to the OpenTelemetry Collector agent, which runs as a DaemonSet.

The subset is fixed by ADR-0019 in the Pagerless repository. Ad, recommendation, accounting, fraud detection, image provider, chatbot, MCP, opamp-server, agent and telemetry-docs are disabled, as are the demo's own Jaeger, Prometheus, Grafana and OpenSearch, because the Pagerless platform provides observability. The 15 Deployments declare 3.3 GiB of memory limits in total, and the collector declares 400 MiB on each node.

The collector's agent ports are container ports only. The chart normally publishes 4317, 4318, 6831, 9411, 14250 and 14268 as node host ports as well, but the Pagerless platform's own collector DaemonSet owns those ports, and a single-node kind cluster can schedule only one DaemonSet per host port. `hack/render-values.yaml` therefore removes the host ports; the demo pods reach the collector through its Service.

The chart's default `flagd-ui` sidecar is also dropped. It serves a browser page for editing flags, which no Scenario uses, and it carries a hardcoded high-entropy session secret that must not enter a public repository. Scenarios change flags by committing to `flagd-config`.

## Layout

| Path | Contents |
| --- | --- |
| `workloads/deployments/` | One Deployment per Workload. |
| `workloads/daemonsets/` | The OpenTelemetry Collector agent. |
| `workloads/services/` | The Services the demo uses. |
| `workloads/configmaps/` | The demo's ConfigMaps, including `flagd-config`. |
| `workloads/serviceaccounts/`, `workloads/clusterroles/`, `workloads/clusterrolebindings/` | The demo's service account and the collector's cluster-wide read access. |
| `hack/render.py` | Renders `workloads/` from the pinned chart. |
| `hack/render-values.yaml` | The component toggles, the pinned init-container images and the Scenario 1 fixture. |
| `hack/check.py` | Checks the inventory, the namespaces and the annotations. |
| `.github/workflows/kubeconform.yml` | The `kubeconform` and inventory pull request check. |

Argo CD syncs `workloads/` recursively into the `sandbox` namespace, and every object names that namespace explicitly.

Every manifest is one Kubernetes object, so that a Workload's file is stable and a change to it is reviewable.

## Annotations

Every Workload declares its own manifest in `pagerless.dev/source-path`, so that Pagerless renders a change against the exact file Argo CD reads. A Workload is a Deployment or a StatefulSet; the collector is a DaemonSet and is never the target of a Triage.

The `cart`, `payment`, `product-catalog` and `email` Workloads declare `workloads/configmaps/flagd-config.yaml` in `pagerless.dev/depends-on-paths`. Their feature flags come from that ConfigMap's `demo.flagd.json` key, so a Rollback may revert a commit that changed it.

## The memory-holder container

The `oom` Scenario needs a container that holds more memory than its limit. The demo's checkout service is a Go program with a 32Mi limit, so the buffer lives in a second container of the same pod, `memory-holder`, which holds a 48 MiB byte array.

In the known-good state that container has a 64Mi request and a 128Mi limit, and it stays running. The `oom` injection lowers both to 32Mi, so the kernel terminates it with `OOMKilled` and it restarts into `CrashLoopBackOff`. Pagerless diagnoses the checkout Workload and raises the limit again. The checkout service container is not affected either way.

## Rendering

The manifests are rendered from the pinned chart and committed as plain YAML, so that Argo CD deploys without Helm and every Scenario injection is an ordinary commit.

| Tool | Version |
| --- | --- |
| Helm | v4.3.2 |
| Chart `opentelemetry-demo` | 0.42.6, appVersion 3.1.0 |
| Chart repository | `https://open-telemetry.github.io/opentelemetry-helm-charts` |
| PyYAML | 6.0.3 |
| kubeconform | v0.8.0, Kubernetes 1.37.0 |

`hack/render.py` runs the pinned command, splits the output into one file per object, sets `namespace: sandbox` and adds the annotations:

```
helm template demo opentelemetry-demo \
  --repo https://open-telemetry.github.io/opentelemetry-helm-charts \
  --version 0.42.6 \
  --namespace sandbox \
  --values hack/render-values.yaml
```

To re-render, from the repository root:

```
python3 -m venv .venv
.venv/bin/pip install --requirement hack/requirements.txt
.venv/bin/python hack/render.py
kubeconform -strict -summary -kubernetes-version 1.37.0 workloads
.venv/bin/python hack/check.py
```

The script is deterministic: the same chart, values and PyYAML version produce the same bytes. Change `hack/render-values.yaml` rather than `workloads/`, and review the rendered diff. It refuses to run if `workloads/` holds manifests outside the directories it manages, which keeps the layout from drifting.

## Known-good state

The tag `known-good` marks the commit in which every Workload is healthy. Pagerless's `make reset` force-resets `main` to this tag. Move the tag only after a change has been verified as healthy.

## Checks and merging

Each pull request runs the `kubeconform` workflow, which validates every manifest under `workloads/` against the Kubernetes 1.37.0 schemas and checks the inventory, the namespaces and the annotations. Branch protection on `main` requires this check. Pull requests opened by Pagerless enable auto-merge, so they merge as soon as the check passes, without a human review. Argo CD then syncs the merge commit.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
