#!/usr/bin/env python3
"""Render the trimmed OpenTelemetry Demo into workloads/ as plain manifests.

The chart version, the component toggles and the Scenario 1 fixture live in
hack/render-values.yaml. This script runs the pinned `helm template` command,
splits the output into one file per object, sets the namespace and adds the
annotations that Pagerless reads. Re-running it is deterministic, so a review of
the resulting diff shows exactly what a chart change did.

Run `python3 hack/check.py` afterwards; it checks the inventory, the namespaces
and the annotations without Helm.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import yaml

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
OUTPUT = REPOSITORY_ROOT / "workloads"
VALUES = REPOSITORY_ROOT / "hack" / "render-values.yaml"

HELM = "helm"
HELM_VERSION = "v4.3.2"
CHART_REPOSITORY = "https://open-telemetry.github.io/opentelemetry-helm-charts"
CHART = "opentelemetry-demo"
CHART_VERSION = "0.42.6"
RELEASE = "demo"
NAMESPACE = "sandbox"

SOURCE_PATH = "pagerless.dev/source-path"
DEPENDS_ON_PATHS = "pagerless.dev/depends-on-paths"
FLAGD_CONFIG = "workloads/configmaps/flagd-config.yaml"
FLAGD_DEPENDENTS = ("cart", "email", "payment", "product-catalog")

# A Target is a Deployment or a StatefulSet, so only those carry the source
# path that Pagerless renders a change against. The collector is a DaemonSet and
# is never the target of a Page.
WORKLOAD_KINDS = ("Deployment", "StatefulSet")
CLUSTER_SCOPED_KINDS = ("ClusterRole", "ClusterRoleBinding")
KIND_DIRECTORIES = {
    "ClusterRole": "clusterroles",
    "ClusterRoleBinding": "clusterrolebindings",
    "ConfigMap": "configmaps",
    "DaemonSet": "daemonsets",
    "Deployment": "deployments",
    "Service": "services",
    "ServiceAccount": "serviceaccounts",
    "StatefulSet": "statefulsets",
}

HEADER = (
    f"# Rendered from the {CHART} chart {CHART_VERSION} by hack/render.py.\n"
    "# Re-render with hack/render.py instead of editing this file.\n"
)


class RenderError(RuntimeError):
    """The chart could not be rendered into the expected layout."""


def check_helm() -> None:
    try:
        version = subprocess.run(
            [HELM, "version", "--short"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RenderError(f"cannot run {HELM}: {error}") from error
    if not version.startswith(HELM_VERSION):
        raise RenderError(f"helm {HELM_VERSION} is required; found {version}")


def helm_template() -> str:
    command = [
        HELM,
        "template",
        RELEASE,
        CHART,
        "--repo",
        CHART_REPOSITORY,
        "--version",
        CHART_VERSION,
        "--namespace",
        NAMESPACE,
        "--values",
        str(VALUES.relative_to(REPOSITORY_ROOT)),
    ]
    result = subprocess.run(command, capture_output=True, text=True, cwd=REPOSITORY_ROOT, check=False)
    if result.returncode:
        raise RenderError(f"helm template failed: {result.stderr.strip()}")
    return result.stdout


def objects(rendered: str) -> list[dict]:
    documents = [document for document in yaml.safe_load_all(rendered) if document is not None]
    if not documents:
        raise RenderError("the chart rendered no objects")
    return documents


def relative_path(document: dict) -> str:
    kind = document.get("kind")
    if kind not in KIND_DIRECTORIES:
        raise RenderError(f"unexpected kind {kind!r} for {document.get('metadata', {}).get('name')!r}")
    name = document.get("metadata", {}).get("name")
    if not name:
        raise RenderError(f"an object of kind {kind} has no name")
    return f"workloads/{KIND_DIRECTORIES[kind]}/{name}.yaml"


def prepare(document: dict) -> None:
    """Set the namespace and the annotations that the Sandbox contract requires."""
    kind = document["kind"]
    metadata = document["metadata"]
    if kind not in CLUSTER_SCOPED_KINDS:
        metadata["namespace"] = NAMESPACE
    if kind not in WORKLOAD_KINDS:
        return
    annotations = metadata.setdefault("annotations", {})
    annotations[SOURCE_PATH] = relative_path(document)
    if metadata["name"] in FLAGD_DEPENDENTS:
        annotations[DEPENDS_ON_PATHS] = FLAGD_CONFIG


def _dumper() -> type[yaml.SafeDumper]:
    """A dumper that writes multiline strings, such as the flagd JSON, as literal blocks.

    A Scenario changes flags by editing that JSON, so it has to stay readable in
    review. Every line must be free of trailing whitespace, which a literal block
    cannot hold; anything else falls back to the default style.
    """

    class Dumper(yaml.SafeDumper):
        pass

    def represent(dumper: yaml.SafeDumper, data: str) -> yaml.ScalarNode:
        lines = data.splitlines()
        if len(lines) > 1 and lines == [line.rstrip() for line in lines]:
            return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
        return dumper.represent_scalar("tag:yaml.org,2002:str", data)

    Dumper.add_representer(str, represent)
    return Dumper


def write(path: Path, document: dict) -> None:
    body = yaml.dump(
        document,
        Dumper=_dumper(),
        sort_keys=False,
        default_flow_style=False,
        width=10**9,
        allow_unicode=True,
    )
    if yaml.safe_load(body) != document:
        raise RenderError(f"{path} does not survive a YAML round trip")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(HEADER + body, encoding="utf-8", newline="\n")


def clear_managed_directories() -> None:
    for directory in sorted(set(KIND_DIRECTORIES.values())):
        shutil.rmtree(OUTPUT / directory, ignore_errors=True)
    stale = sorted(str(path.relative_to(REPOSITORY_ROOT)) for path in OUTPUT.rglob("*.yaml"))
    if stale:
        raise RenderError(
            "workloads/ holds manifests that this script does not manage, so the layout has drifted: "
            + ", ".join(stale)
        )


def main() -> int:
    check_helm()
    documents = objects(helm_template())
    clear_managed_directories()
    counts: dict[str, int] = {}
    for document in documents:
        prepare(document)
        path = REPOSITORY_ROOT / relative_path(document)
        write(path, document)
        kind = document["kind"]
        counts[kind] = counts.get(kind, 0) + 1
    total = sum(counts.values())
    inventory = ", ".join(f"{count} {kind}" for kind, count in sorted(counts.items()))
    print(f"Rendered {total} objects from {CHART} {CHART_VERSION}: {inventory}.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RenderError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
