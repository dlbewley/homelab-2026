# nmstate

Deploys the Kubernetes NMState Operator config and the secondary networks VMs
use to reach the lab.

## base

| Resource | Purpose |
|---|---|
| `NMState` | Deploys the handler DaemonSet and registers NNCP/NNS/NNCE CRDs (sync-wave 0) |
| `ClusterUserDefinedNetwork` `machinenet` | Localnet CUDN for namespaces labeled `network/machine=""` |

## overlays/hub

Network configuration unique to the 'hub' cluster.

| Resource | Purpose |
|---|---|
| `NodeNetworkConfigurationPolicy` `br-vmdata` | OVS bridge on each virtualization node's trunk NIC (`ens224`), mapped to `physnet-vmdata` |

