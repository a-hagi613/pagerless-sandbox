# pagerless-sandbox

Demo Workloads for [Pagerless](https://github.com/a-hagi613/pagerless). Argo CD deploys the manifests in this repository, Scenarios inject failures into it as commits, and Pagerless remediates failures by opening pull requests against it.

This repository is a GitHub template. Create your own copy, then point Pagerless at it with `SANDBOX_URL` in the `.env` file that `make up` writes.

### Setting up your copy

Repository settings and branch protection are not copied with a template, so configure your copy after creating it:

1. Enable auto-merge in the repository settings (Settings, General, Pull Requests).
2. Add a branch protection rule for `main` that requires the `kubeconform` status check. Pagerless opens pull requests with auto-merge, so this rule is what makes them wait for validation.
3. Allow force pushes for `main` if you want `make reset` to work without an administrator bypass.
4. Create the `known-good` tag on the commit in which every Workload is healthy.

## Layout

| Path | Contents |
| --- | --- |
| `workloads/` | Plain Kubernetes manifests, one directory per Workload. Argo CD syncs this directory into the `sandbox` namespace. |
| `.github/workflows/kubeconform.yml` | The `kubeconform` pull request check. |

Every manifest that Pagerless may remediate declares its own path in the `pagerless.dev/source-path` annotation, so that Pagerless can render a change against the exact file Argo CD reads.

## Workloads

| Workload | Kind | Scenario | Known-good resources |
| --- | --- | --- | --- |
| `checkout` | Deployment | `oom` | 64 MiB request, 128 MiB limit |

The `checkout` container holds a 48 MiB buffer in memory. With the known-good limit it stays running. The `oom` Scenario lowers the request and limit to 32 MiB, so the kernel kills the container with reason `OOMKilled`.

## Known-good state

The tag `known-good` marks the commit in which every Workload is healthy. Pagerless's `make reset` force-resets `main` to this tag. Move the tag only after a change has been verified as healthy.

## Checks and merging

Each pull request runs the `kubeconform` workflow, which validates every manifest under `workloads/` against the Kubernetes 1.37.0 schemas. Branch protection on `main` requires this check. Pull requests opened by Pagerless enable auto-merge, so they merge as soon as the check passes, without a human review. Argo CD then syncs the merge commit.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
