# Chaos Mesh

The `chaos-mesh` Argo CD Application renders chart **2.8.8** from `https://charts.chaos-mesh.org` into `chaos-mesh`. It exists for Scenario 9, externally caused CPU stress, whose experiment is applied outside Git by `make break SCENARIO=cpu`.

The chart version was verified on the [v2.8.8 release](https://github.com/chaos-mesh/chaos-mesh/releases/tag/v2.8.8) and in the repository's Helm index (`version: 2.8.8`, `appVersion: 2.8.8`, published 2026-11-06). The chart pins its controller, daemon and dashboard images to the matching `v2.8.8` tag, and `values.yaml` restates the tag so an upgrade of the chart cannot silently change it.

## Runtime settings

- `chaosDaemon.runtime: containerd` and `chaosDaemon.socketPath: /run/containerd/containerd.sock`. The chart defaults to Docker; its own values file documents this pair for kind and for any cluster whose CRI is containerd. The daemon mounts the socket's directory at `/host-run` and passes `/host-run/containerd.sock` to `--runtime-socket-path`.
- `controllerManager.replicaCount: 1`. The default of three replicas is a multi-node availability setting, and the local cluster has one node.
- `dashboard.create: false`, `dnsServer.create: false`, and `enableProfiling: false`. Pagerless creates `StressChaos` objects and reads their status; it never uses the Chaos Dashboard, DNS chaos, or the pprof endpoints.

The chaos daemon is a privileged DaemonSet with `hostPID`, as the chart requires.

The chart's containerd settings were verified on the pinned kind node image (`kindest/node:v1.37.0`, containerd 2.3.4): a `StressChaos` object reached `AllInjected`, the controller recorded the target container, and `stress-ng` ran inside the pod's cgroup until the object was deleted.

## Argo CD rendering

The chart issues its webhook and daemon certificates with `genCA` on every render and stamps a random `rollme` annotation on the controller and daemon pod templates. Without an `ignoreDifferences` entry, every reconciliation would show a diff, reissue the certificates and restart both pods. The Application ignores those fields, so it stays Synced. A chart upgrade or a values change still applies the rest of the manifests, including freshly issued certificates.

The Application also sets `ServerSideApply=true`, because the Chaos Mesh CRDs exceed the client-side apply annotation limit.

## StressChaos access

The experiment itself lives in `scenarios/cpu/stresschaos.yaml` and is applied by `hack/cpu-stress.sh`, not by this chart. Reading the active experiment is the product's concern: the cluster RBAC that lets Pagerless read `chaos-mesh.org/v1alpha1` `StressChaos` objects comes from the product's chart, not from this repository.
