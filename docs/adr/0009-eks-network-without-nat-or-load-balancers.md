# ADR-0009: EKS without NAT gateways or load balancers

- **Status:** Accepted
- **Date:** 2026-11-16

## Context

The cloud environment exists to demonstrate the stack on EKS at minimal cost. A NAT gateway or a load balancer would cost more than the cluster's runtime across all planned sessions.

## Decision

- Nodes run in public subnets, with security groups that permit no inbound traffic.
- The dashboard and Grafana are reached through `kubectl port-forward`.
- Bedrock is reached through its public endpoint.
- Terraform state is stored in S3 with native lockfile locking.
- The cluster is created and destroyed per session with `make cloud-up` and `make cloud-down`.

## Consequences

- This deliberately departs from the conventional private-subnet layout and is not a production network design.
- There is no persistent cloud environment; every session starts from Terraform.
