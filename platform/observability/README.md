# Observability stack

Argo CD deploys these components into the `monitoring` namespace. Each Application is defined in [`platform/apps/templates`](../apps/templates) and reads its Helm values from this directory, at the platform revision.

| Component | Chart | Version | Values |
| --- | --- | --- | --- |
| kube-prometheus-stack (Prometheus, Alertmanager, Grafana, kube-state-metrics) | `prometheus-community/kube-prometheus-stack` | 93.3.0 | [`kube-prometheus-stack/values.yaml`](kube-prometheus-stack/values.yaml) |
| Loki, single-binary mode | `grafana-community/loki` | 21.3.0 | [`loki/values.yaml`](loki/values.yaml) |
| Tempo, single-binary mode | `grafana-community/tempo` | 3.2.1 | [`tempo/values.yaml`](tempo/values.yaml) |
| OpenTelemetry Collector, DaemonSet | `open-telemetry/opentelemetry-collector` | 0.178.3 | [`opentelemetry-collector/values.yaml`](opentelemetry-collector/values.yaml) |

## Container logs

The OpenTelemetry Collector reads `/var/log/pods` on every node, attaches Kubernetes metadata, and exports the records over OTLP to Loki. Loki stores them with resource attributes such as `k8s_namespace_name` and `k8s_pod_name` as labels. Grafana queries them through the Loki data source. Pagerless reads the same pod logs through the Kubernetes API, so a Page still has native log evidence when this stack is unavailable.

## Alert rules

[`alerts/`](alerts) holds one PrometheusRule per alert. Every firing alert carries `pagerless.dev/watch: "true"`, the v2 opt-in the receiver checks, and `pagerless_page: "true"`, which only selects the alert for the Alertmanager route. The same labels carry `namespace` and `deployment` (or `statefulset`), which name the Target; the receiver resolves the Target from a single Target label, or from a pod label through its owner chain.

| Rule | File | Fires when |
| --- | --- | --- |
| `ContainerOOMKilled` | [`alerts/oomkilled.yaml`](alerts/oomkilled.yaml) | kube-state-metrics reports a container that was terminated with reason `OOMKilled`. |
| `ServiceErrorRateHigh` | [`alerts/service-error-rate.yaml`](alerts/service-error-rate.yaml) | More than one percent of a Target's server spans are failing, at more than one error every three minutes, for three minutes. |
| `ContainerMemoryGrowth` | [`alerts/memory-growth.yaml`](alerts/memory-growth.yaml) | A container's working set grew by more than a quarter of its own memory limit in ten minutes, and the pod is older than fifteen minutes. |

kube-state-metrics reports the pod that was terminated, so the OOMKilled rule joins the pod to its owner: a Deployment is reached through its ReplicaSet, and a StatefulSet directly. The memory rule joins the pod the same way and reads cAdvisor's `container_memory_working_set_bytes`. The error-rate rule reads the span metrics that the demo's collector produces.

Four Targets are left out of the error-rate rule because they report errors in the demo's known-good state, and a threshold over them would fire continuously: the frontend and frontend-proxy answer their recommendation and ad routes with an error because ADR-0019 does not deploy those components, and checkout and shipping report failures whenever the demo's own calls time out. The Targets the Scenarios target are error-free in the known-good state, so any error rate from them is a fault.

The Alertmanager route in [`kube-prometheus-stack/values.yaml`](kube-prometheus-stack/values.yaml) posts every routed alert to the v2 receiver at `http://pagerless-server.pagerless.svc:8080/v1/webhooks/alerts`. The receiver's Alertmanager dialect authenticates with a bearer token: the same value is `ALERTMANAGER_WEBHOOK_TOKEN` in the `pagerless-credentials` Secret and the `token` key of the `pagerless-alertmanager` Secret that Alertmanager mounts. The bootstrap writes both from one generated value, so no credential enters Git.

The receiver accepts a firing alert only when it carries the opt-in, resolves exactly one Target, and the namespace is in the allowlist. A firing alert joins the Active Page for that Target, or opens one; a resolved alert closes only its own Trigger. The other four dialects (Grafana, Datadog, SNS and the generic JSON body) are available to any installation that configures their credentials, but the showcase configures Alertmanager only.

## Span metrics

The demo's OpenTelemetry Collector runs the `span_metrics` connector over every span, so it already counts calls and failures per service and status. Its metrics pipeline exports them to `http://prometheus:9090/api/v1/otlp`, which it resolves in its own namespace; the demo's own Prometheus is disabled ([ADR-0019](../adr/0019-opentelemetry-demo-as-rendered-manifests.md)). [`otlp-receiver/prometheus-service.yaml`](otlp-receiver/prometheus-service.yaml) is an `ExternalName` Service that gives the `sandbox` namespace the name `prometheus` for the platform's Prometheus, and the kube-prometheus-stack values enable that Prometheus's OTLP receiver.

The result is the `traces_span_metrics_calls_total` counter. Prometheus normalizes `status.code` to `status_code`, and its value for a failed span is `STATUS_CODE_ERROR`, which was read from the live metric. The collector does not attach the pod's namespace and Deployment to every service's metrics, so the rule keys each series by `service_name`, which every span carries and which the demo names after the Deployment, and sets the namespace that the Sandbox fixes. `ServiceErrorRateHigh` then compares the failing server spans with all server spans of the same Target. The same counter carries every other span metric, so the Target dashboards can chart throughput and latency beside the alert.

## Pagerless metrics

`pagerless-server` serves its own metrics on port 9090. [`monitors/pagerless-server.yaml`](monitors/pagerless-server.yaml) is a `PodMonitor` that selects the server's pod port in the `pagerless` namespace, so Prometheus scrapes it every 30 seconds. It is a `PodMonitor` rather than a `ServiceMonitor` because the v2 chart's Service exposes the Portal and the report API, not the metrics port.

| Metric | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `pagerless_pages` | gauge | `phase` | Pages currently in each Phase, collected from the Page cache at scrape time. |
| `pagerless_proposals_total` | counter | `action` | Validated Proposals, including a Proposal re-validated under a new hash. |
| `pagerless_decisions_total` | counter | `decision` | Human decisions: `Approved` or `Rejected`. |
| `pagerless_verifications_total` | counter | `outcome` | Verification outcomes: `Recovered` or `NotRecovered`. |
| `pagerless_time_to_recovered_seconds` | histogram | — | Seconds from Page creation to Recovered. |
| `pagerless_page_input_tokens` | gauge | `page` | Input tokens the Page's investigation read, including cached tokens. |
| `pagerless_page_output_tokens` | gauge | `page` | Output tokens the Page's investigation wrote. |
| `pagerless_page_cost_usd` | gauge | `page` | Estimated model cost of the Page in United States dollars. |

The per-Page series exist only while the Page resource does, which retention bounds to seven days after a terminal Phase.

## Grafana dashboards

[`dashboards/kustomization.yaml`](dashboards/kustomization.yaml) generates ConfigMaps from [`dashboards/target-metrics.json`](dashboards/target-metrics.json) and [`dashboards/target-logs.json`](dashboards/target-logs.json), and labels them `grafana_dashboard: "1"`. The kube-prometheus-stack Grafana sidecar discovers that label in every namespace and provisions:

- the **Pagerless Target metrics** dashboard (UID `pagerless-target`), which charts a Target's CPU, memory, restarts and ready pods;
- the **Pagerless Target logs** dashboard (UID `pagerless-target-logs`), which shows a Target's container logs from Loki.

The dashboard that charts the product's own metrics ships in the product's chart, because it describes the product rather than the demo.

The Target dashboards take `namespace` and `target` variables. The Grafana values pin the `loki` and `tempo` data source UIDs that the log dashboard references. A Page's evidence is shown as Findings in the Portal and as `kubectl page show` output, so neither dashboard is embedded in the product.

## Local credentials

The Grafana administrator password is generated into the `kube-prometheus-stack-grafana` Secret in the `monitoring` namespace. It exists only in the session's cluster: `make down` deletes a kind cluster and `make cloud-down` destroys the EKS one.
