#!/usr/bin/env python3
"""Check the rendered Sandbox manifests without Helm.

The manifests in workloads/ are generated, so the checks are about the contract
that Pagerless depends on: the inventory of the trimmed demo, the namespace of
every object, and the annotations that name a Workload's manifest and its
dependency paths. Scenario injections change resources, not this contract, so
this script passes on an injection pull request as well.

It reads YAML only, so it needs PyYAML and nothing else. Run it after
hack/render.py, and in CI on every pull request.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
OUTPUT = REPOSITORY_ROOT / "workloads"
NAMESPACE = "sandbox"

SOURCE_PATH = "pagerless.dev/source-path"
DEPENDS_ON_PATHS = "pagerless.dev/depends-on-paths"
FLAGD_CONFIG = "workloads/configmaps/flagd-config.yaml"
FLAGD_KEY = "demo.flagd.json"
FLAGD_DEPENDENTS = ("cart", "email", "payment", "product-catalog")

WORKLOAD_KINDS = ("Deployment", "StatefulSet")
CLUSTER_SCOPED_KINDS = ("ClusterRole", "ClusterRoleBinding")

# The subset that ADR-0019 fixes. A chart re-render that drops or adds a
# component has to change this list deliberately.
EXPECTED_WORKLOADS = (
    "astronomy-db",
    "cart",
    "checkout",
    "currency",
    "email",
    "flagd",
    "frontend",
    "frontend-proxy",
    "kafka",
    "load-generator",
    "payment",
    "product-catalog",
    "quote",
    "shipping",
    "valkey-cart",
)
EXPECTED_DAEMONSETS = ("otel-collector-agent",)


class CheckError(RuntimeError):
    """The rendered manifests do not satisfy the Sandbox contract."""


def manifests() -> dict[tuple[str, str], tuple[str, dict]]:
    found: dict[tuple[str, str], tuple[str, dict]] = {}
    for path in sorted(OUTPUT.rglob("*.yaml")):
        relative = path.relative_to(REPOSITORY_ROOT).as_posix()
        try:
            document = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as error:
            raise CheckError(f"{relative} is not valid YAML: {error}") from error
        if not isinstance(document, dict) or "kind" not in document:
            raise CheckError(f"{relative} does not hold one Kubernetes object")
        key = (document["kind"], document["metadata"]["name"])
        if key in found:
            raise CheckError(f"{key[0]} {key[1]} is declared in both {found[key][0]} and {relative}")
        found[key] = (relative, document)
    if not found:
        raise CheckError("workloads/ holds no manifests")
    return found


def check_inventory(found: dict[tuple[str, str], tuple[str, dict]]) -> None:
    workloads = sorted(name for kind, name in found if kind in WORKLOAD_KINDS)
    if workloads != sorted(EXPECTED_WORKLOADS):
        raise CheckError(f"the Workloads are {workloads}, expected {sorted(EXPECTED_WORKLOADS)}")
    daemonsets = sorted(name for kind, name in found if kind == "DaemonSet")
    if daemonsets != sorted(EXPECTED_DAEMONSETS):
        raise CheckError(f"the DaemonSets are {daemonsets}, expected {sorted(EXPECTED_DAEMONSETS)}")


def check_placement(found: dict[tuple[str, str], tuple[str, dict]]) -> None:
    for (kind, name), (relative, document) in sorted(found.items()):
        expected = f"workloads/{kind.lower()}s/{name}.yaml"
        if relative != expected:
            raise CheckError(f"{kind} {name} is at {relative}, expected {expected}")
        if kind in CLUSTER_SCOPED_KINDS:
            if document["metadata"].get("namespace"):
                raise CheckError(f"{kind} {name} is cluster-scoped but names a namespace")
            continue
        if document["metadata"].get("namespace") != NAMESPACE:
            raise CheckError(f"{kind} {name} is not in the {NAMESPACE} namespace")


def check_annotations(found: dict[tuple[str, str], tuple[str, dict]]) -> None:
    for (kind, name), (relative, document) in sorted(found.items()):
        annotations = document["metadata"].get("annotations") or {}
        if kind in WORKLOAD_KINDS:
            declared = annotations.get(SOURCE_PATH)
            if declared != relative:
                raise CheckError(f"Workload {name} declares {SOURCE_PATH}={declared!r}, expected {relative!r}")
            if name in FLAGD_DEPENDENTS and annotations.get(DEPENDS_ON_PATHS) != FLAGD_CONFIG:
                raise CheckError(f"Workload {name} does not declare {FLAGD_CONFIG} in {DEPENDS_ON_PATHS}")
            if name not in FLAGD_DEPENDENTS and DEPENDS_ON_PATHS in annotations:
                raise CheckError(f"Workload {name} declares {DEPENDS_ON_PATHS} without reading the flagd configuration")
        elif SOURCE_PATH in annotations:
            raise CheckError(f"{kind} {name} is not a Workload but declares {SOURCE_PATH}")
    flagd = found.get(("ConfigMap", "flagd-config"))
    if flagd is None:
        raise CheckError(f"the ConfigMap {FLAGD_CONFIG} is missing")
    if FLAGD_KEY not in (flagd[1].get("data") or {}):
        raise CheckError(f"the ConfigMap flagd-config has no {FLAGD_KEY} key")


def main() -> int:
    found = manifests()
    check_inventory(found)
    check_placement(found)
    check_annotations(found)
    workloads = sum(1 for kind, _ in found if kind in WORKLOAD_KINDS)
    print(f"Checked {len(found)} objects, including {workloads} Workloads with their source paths and dependencies.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CheckError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
