# Cloud-only manifests

The resources that exist on EKS and have no local counterpart. Everything else in `platform/` is the same app-of-apps that runs on kind, which is the point: the two environments differ only in the platform under them.

| Path | Applied by | Purpose |
| --- | --- | --- |
| `karpenter/ec2nodeclass.yaml` | `make cloud-up` renders it | Which network, role and AMI Karpenter launches nodes from, and the `project=pagerless` tag every instance carries. |
| `karpenter/nodepool.yaml` | `make cloud-up` renders it | The only capacity Karpenter may buy: x86_64 Spot, within a 12 vCPU and 24 GiB limit. |
| `storage/storage-class.yaml` | `make cloud-up` | The default gp3 class named `standard`, whose volumes carry `project=pagerless`. |

The two Karpenter documents are templates. `make cloud-up` replaces `__CLUSTER_NAME__` and `__NODE_ROLE_NAME__` from the Terraform outputs, so the cluster's name and the node role's name exist in Terraform and nowhere else. `make cloud-check` proves the placeholders are still the ones the substitution expects. The StorageClass is applied unchanged.

`make cloud-down` deletes the NodePools and NodeClaims, then the claims, and waits for both before it destroys the cluster: those instances and volumes are not in Terraform's state, so a destroy alone would leave them billing. The CSI driver deletes a volume asynchronously, so a final sweep deletes any EBS volume that still carries `project=pagerless`, and the teardown check queries the volumes directly as well as through the tagging index. A failed AWS query fails the check: an account that cannot be read is not an empty account.
