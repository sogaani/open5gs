# open5gs Helm chart

Deploys an Open5GS 5G core with **one pod per NF**, MongoDB, the Open5GS WebUI and an
in-cluster UERANSIM gNB/UE simulator.

| Component | Kind | Service | Notes |
|-----------|------|---------|-------|
| nrf, scp, amf, ausf, udm, udr, pcf, nssf, bsf | Deployment | ClusterIP :7777 | SBI binds the pod IP and advertises the Service FQDN |
| smf-\<dnn\> (one per `dnns[]`) | Deployment | ClusterIP :7777, :8805/UDP | one SMF per DNN; advertises only its DNN in SmfInfo so the AMF selects it by DNN |
| amf (N2) | - | headless `*-amf-ngap` :38412/SCTP | gNB resolves it to the AMF pod IP |
| upf-\<dnn\> (one per `dnns[]`) | Deployment | ClusterIP :8805/UDP | one UPF per DNN; privileged init container creates `ogstun`, enables forwarding and MASQUERADEs UE traffic |
| mongodb | StatefulSet + PVC | ClusterIP :27017 | seeded with the WebUI admin account (admin / 1423) |
| webui | Deployment | **LoadBalancer** :9999 | `webui.service.loadBalancerIP` is passed to Cilium LB-IPAM |
| gnb-\<name\> (one per `ueransim.gnbs[]`) | Deployment (Recreate) | ClusterIP :4997/UDP (optionally pinned via `clusterIP`) | UERANSIM `nr-gnb`; UEs use the Service FQDN in `gnbSearchList`, so a replaced gNB pod is found again |
| ue-\<name\> (one per `ueransim.ues[]`) | Deployment | - | UERANSIM `nr-ue`, needs `NET_ADMIN` + `/dev/net/tun` |
| subscribers | post-install/upgrade Job | - | inserts `subscribers[]` into MongoDB, skips existing IMSIs |

## Install

```bash
# images on ghcr.io are private by default: either make them public or
kubectl create ns open5gs
kubectl -n open5gs create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<github user> --docker-password=<PAT with read:packages>

helm upgrade --install open5gs ./helm/open5gs -n open5gs \
  --set image.tag=sogaani-test \
  --set webui.image.tag=sogaani-test \
  --set ueransim.image.tag=sogaani-test \
  --set 'imagePullSecrets[0].name=ghcr-pull'
```

## Key values

| Value | Default | Meaning |
|-------|---------|---------|
| `image.repository` / `image.tag` | `ghcr.io/sogaani/ubuntu-latest-open5gs-build` / `sogaani-test` | Image used by every Open5GS NF |
| `webui.image.*`, `ueransim.image.*` | ghcr.io/sogaani/... | WebUI and UERANSIM images |
| `webui.service.loadBalancerIP` | `172.31.254.10` | LB address (Cilium annotation + `spec.loadBalancerIP`); `""` lets the pool choose |
| `plmn.mcc` / `plmn.mnc` / `tac` | `999` / `70` / `1` | Applied to AMF, NRF, gNB, UEs |
| `slices[]` | `[{sst: 1}]` | S-NSSAIs in AMF `plmn_support`, NSSF, SMF `info`, gNB |
| `dnns[]` | one `internet` on `10.45.0.0/16` | Each DNN has `subnet` and `gateway`, and gets its own SMF `smf-<dnn>` and UPF `upf-<dnn>` (`nodeSelector` applies to both) |
| `subscribers[]` | the UERANSIM sample UE | IMSI, K, OPc, sst, dnn, optional static `ipv4` |
| `ueransim.enabled` | `true` | Deploy gNB and UEs |
| `ueransim.gnbs[]` | one gNB `gnb1` | One `nr-gnb` pod + ClusterIP Service per entry; `nci` must be unique, `clusterIP` pins the Service address, `tac`/`nodeSelector` optional |
| `ueransim.ues[]` | one UE matching `subscribers[0]` | One `nr-ue` pod per entry; `gnbs: [..]` limits `gnbSearchList` (default: all gNBs) |
| `mongodb.persistence.*` | 2Gi PVC | Set `enabled: false` for an emptyDir |

Example: three DNNs, which yields three SMF/UPF pairs (`smf-internet`/`upf-internet`, `smf-internet2`/`upf-internet2`, `smf-ims`/`upf-ims`). This mirrors a full MVNO bringing its own SMF and UPF to an MNO core: the shared AMF discovers the SMF for a PDU session through the NRF by DNN.

```yaml
dnns:
  - { name: internet,  subnet: 10.45.0.0/16, gateway: 10.45.0.1 }
  - { name: internet2, subnet: 10.46.0.0/16, gateway: 10.46.0.1 }
  - { name: ims,       subnet: 10.47.0.0/16, gateway: 10.47.0.1, nodeSelector: { kubernetes.io/hostname: node-b } }
```

## How addressing works

* Every NF binds `__POD_IP__` (substituted from the downward API at start) and advertises
  its ClusterIP Service FQDN on SBI, so discovery through NRF/SCP returns stable names.
* SMF selection: each `smf-<dnn>` registers `info.s_nssai[].dnn = [<dnn>]` with the NRF; the AMF asks the NRF for an SMF serving the requested DNN and gets exactly that one.
* PFCP: `smf-<dnn>` talks only to `*-upf-<dnn>` ClusterIP (UDP 8805). The UPF reports its own pod
  IP as the GTP-U endpoint, so the gNB sends N3 traffic straight to the UPF pod.
* N2: the gNB resolves the headless `*-amf-ngap` Service and opens SCTP to the AMF pod,
  avoiding SCTP Service load balancing. UERANSIM 3.3.0 resolves FQDNs itself, so the gNB
  config carries the FQDN and binds `eth0` directly.
* RLS (UE <-> gNB, UDP 4997): UEs target the gNB's ClusterIP Service FQDN. The ClusterIP is
  stable across gNB pod restarts (and can be pinned with `clusterIP`), so UEs re-find the
  cell without a restart. Multiple gNBs are supported; a UE lists one or more of them.
* UE subnets exist only inside the UPF pod (`ogstun`) and in GTP-U payloads. They are
  MASQUERADEd to the pod IP, so the CNI needs no knowledge of them. They must not overlap
  the pod CIDR, the Service CIDR or the node network (check Cilium's `cluster-pool-ipv4-cidr`).

## Cluster requirements

* Privileged init container allowed for the UPF (writes `net.ipv4.ip_forward`).
* `/dev/net/tun` on the nodes (UPF and UE pods mount it via hostPath).
* `iptable_nat` / nf_tables available on the nodes (the UPF pod runs `iptables -t nat`).
* A LoadBalancer implementation for the WebUI Service (Cilium LB-IPAM assumed).
* Cilium: N2 is SCTP pod-to-pod. If the gNB never completes NG Setup, enable SCTP in
  Cilium (`sctp.enabled=true` in the Helm values / `enable-sctp: "true"` in the ConfigMap).

## Verify

```bash
kubectl -n open5gs get pods
kubectl -n open5gs logs deploy/open5gs-gnb-gnb1       # expect "NG Setup procedure is successful"
kubectl -n open5gs logs deploy/open5gs-ue-ue1         # expect "PDU Session establishment is successful"
UE=$(kubectl -n open5gs get pod -l app.kubernetes.io/component=ue-ue1 -o jsonpath='{.items[0].metadata.name}')
kubectl -n open5gs exec $UE -- ip addr show uesimtun0
kubectl -n open5gs exec $UE -- ping -I uesimtun0 -c 3 8.8.8.8
```
