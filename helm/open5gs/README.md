# open5gs Helm chart

Deploys an Open5GS 5G core with **one pod per NF**, MongoDB, the Open5GS WebUI and an
in-cluster UERANSIM gNB/UE simulator. Optionally (`epc.enabled`) it adds the 4G core
(MME, HSS, SGW-C, SGW-U, PCRF, with the SMF/UPF acting as PGW) and srsRAN_4G eNB/UE pods
(`srsran.enabled`), see "4G / EPC".

| Component | Kind | Service | Notes |
|-----------|------|---------|-------|
| nrf, scp, amf, ausf, udm, udr, pcf, nssf, bsf | Deployment | ClusterIP :7777 | SBI binds the pod IP and advertises the Service FQDN |
| smf-\<dnn\>[-sst\<N\>[-sd\<hex\>]] (one per `dnns[]`) | Deployment | ClusterIP :7777, :8805/UDP | one SMF per entry; advertises only its DNN (and only its S-NSSAI when `sst` is set) in SmfInfo so the AMF selects it by S-NSSAI + DNN |
| amf (N2) | - | headless `*-amf-ngap` :38412/SCTP | gNB resolves it to the AMF pod IP |
| upf-\<dnn\>[-sst\<N\>[-sd\<hex\>]] (one per `dnns[]`) | Deployment | ClusterIP :8805/UDP | one UPF per entry; privileged init container creates `ogstun`, enables forwarding and MASQUERADEs UE traffic |
| mongodb | StatefulSet + PVC | ClusterIP :27017 | seeded with the WebUI admin account (admin / 1423) |
| webui | Deployment | **LoadBalancer** :9999 | `webui.service.loadBalancerIP` is passed to Cilium LB-IPAM |
| gnb-\<name\> (one per `ueransim.gnbs[]`) | Deployment (Recreate) | ClusterIP :4997/UDP (optionally pinned via `clusterIP`) | UERANSIM `nr-gnb`; UEs use the Service FQDN in `gnbSearchList`, so a replaced gNB pod is found again |
| ue-\<name\> (one per `ueransim.ues[]`) | Deployment | - | UERANSIM `nr-ue`, needs `NET_ADMIN` + `/dev/net/tun` |
| subscribers | post-install/upgrade Job | - | inserts `subscribers[]` into MongoDB, skips existing IMSIs |
| mme, hss, pcrf, sgwc, sgwu (`epc.enabled`) | Deployment | mme :2123/UDP :3868, headless `*-mme-s1ap` :36412/SCTP; hss/pcrf :3868; sgwc :2123/UDP :8805/UDP; sgwu :8805/UDP | 4G core; S6a/Gx over TCP, Diameter identity = Service FQDN |
| lte-\<name\> (one per `srsran.ues[]`, `srsran.enabled`) | Deployment (Recreate) | - | one srsRAN_4G `srsenb` + `srsue` pair per pod over ZMQ; needs `NET_ADMIN` + `/dev/net/tun` |

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
| `dnns[]` | one `internet` on `10.45.0.0/16` | Each entry has `name`, `subnet`, `gateway` and optional `sst`/`sd`, and gets its own SMF/UPF pair: `smf-<dnn>`/`upf-<dnn>`, or `smf-<dnn>-sst<N>[-sd<hex>]`/`upf-...` when `sst` is set (`nodeSelector` applies to both) |
| `subscribers[]` | the UERANSIM sample UE | IMSI, K, OPc, sst, dnn, optional static `ipv4` |
| `ueransim.enabled` | `true` | Deploy gNB and UEs |
| `ueransim.gnbs[]` | one gNB `gnb1` | One `nr-gnb` pod + ClusterIP Service per entry; `nci` must be unique, `clusterIP` pins the Service address, `tac`/`nodeSelector` optional |
| `ueransim.ues[]` | one UE matching `subscribers[0]` | One `nr-ue` pod per entry; `gnbs: [..]` limits `gnbSearchList` (default: all gNBs) |
| `mongodb.persistence.*` | 2Gi PVC | Set `enabled: false` for an emptyDir |
| `ueransim.ues[].hplmn` | unset (= `plmn`) | Home PLMN of the USIM (`{mcc, mnc}`); set it to simulate a roaming UE of another PLMN |
| `roaming.enabled` | `false` | Act as a Visited PLMN: deploy a SEPP and advertise 3GPP FQDNs (see Roaming) |
| `roaming.fqdnNfs` | `{nrf: 192.96.0.40}` | NFs that advertise `<nf>.5gc.mnc<MNC>.mcc<MCC>.3gppnetwork.org:7777`, with their pinned ClusterIP |
| `roaming.peers[]` | the `mvno` release | Peer PLMNs: `mcc`, `mnc`, `sepp.host` (peer SEPP Service FQDN), `sepp.n32cPort`, `sepp.n32fPort` |
| `roaming.sepp.*` | ports 7778/7779, Secret `sepp-tls` | N32 identity (`sender`), listener ports, TLS Secret (`tls.existingSecret` or `tls.ca/cert/key` PEM), `tls.verifyClient` |
| `roaming.pcf.policy` | `[]` (auto) | V-PCF local policy for roaming SUPIs; auto-generates one entry per peer |
| `dnns[].clusterIP` | unset | Required with roaming: pinned ClusterIP of that SMF's Service |
| `epc.enabled` | `false` | Deploy MME, HSS, SGW-C, SGW-U, PCRF and turn the SMF/UPF of the first `dnns[]` entry per DNN name into the PGW for that APN (`dnns[].epc: false` skips an entry) |
| `epc.realm` | `""` (= `epc.mnc<MNC>.mcc<MCC>.3gppnetwork.org`) | Diameter realm of this PLMN |
| `epc.mme.{name,gid,code}` | `open5gs-mme0`, 2, 1 | MME name and GUMMEI |
| `epc.pgwInHss` | `false` | Home PLMN only: store the PGW address (`dnns[].clusterIP`) in every subscriber so a visited MME learns it over S6a |
| `epc.diameter.allowedPeers` | `[]` | Extra inbound Diameter peers for HSS/PCRF (acl_wl patterns; own namespace is always allowed) |
| `roaming.peers[].epc.hss` | unset | Diameter identity of the peer's home HSS: adds an MME `hss_map` entry for IMSIs of that PLMN |
| `srsran.enabled` | `false` | Deploy one srsRAN_4G eNB+UE pod per `srsran.ues[]` (requires `epc.enabled`) |
| `srsran.nPrb` / `baseSrate` / `dlEarfcn` | 25 / `5.76e6` / 3350 | Cell bandwidth, ZMQ sample rate (integer multiple of the PHY rate), EARFCN |
| `srsran.ues[]` | one UE `lte1` | `name`, `imsi`, `key`, `opc`, `apn`, `enbId` (unique), `pci`, optional `tac`, `cellId`, `imei`, `resources`, `nodeSelector` |

Example: three DNNs, which yields three SMF/UPF pairs (`smf-internet`/`upf-internet`, `smf-internet2`/`upf-internet2`, `smf-ims`/`upf-ims`). This mirrors a full MVNO bringing its own SMF and UPF to an MNO core: the shared AMF discovers the SMF for a PDU session through the NRF by DNN.

```yaml
dnns:
  - { name: internet,  subnet: 10.45.0.0/16, gateway: 10.45.0.1 }
  - { name: internet2, subnet: 10.46.0.0/16, gateway: 10.46.0.1 }
  - { name: ims,       subnet: 10.47.0.0/16, gateway: 10.47.0.1, nodeSelector: { kubernetes.io/hostname: node-b } }
```

### Splitting the same DNN by slice (SST)

Set `sst` (and optionally `sd`) on a `dnns[]` entry to serve that DNN only for one S-NSSAI.
The SMF then advertises just that S-NSSAI + DNN in SmfInfo, so the AMF routes a PDU session for
`internet` to a different SMF/UPF pair depending on the UE's slice. The S-NSSAI must also be
listed in `slices[]` (the chart fails to render otherwise, because the AMF would reject it). Give
each pair its own UE subnet: overlapping pools would work at the IP level here, since every UPF pod
NATs behind its own pod IP in its own network namespace, but the Open5GS BSF indexes PCF bindings
by UE IPv4 alone, so duplicate UE addresses across slices collide there, and distinct subnets make
logs and captures attributable to a slice.

```yaml
slices:
  - sst: 1      # MNO
  - sst: 2      # MVNO
dnns:
  - { name: internet, sst: 1, subnet: 10.45.0.0/16, gateway: 10.45.0.1 }   # smf-internet-sst1 / upf-internet-sst1
  - { name: internet, sst: 2, subnet: 10.46.0.0/16, gateway: 10.46.0.1 }   # smf-internet-sst2 / upf-internet-sst2
subscribers:
  - { imsi: "999700000000001", key: ..., opc: ..., sst: 1, dnn: internet }
  - { imsi: "999700000000002", key: ..., opc: ..., sst: 2, dnn: internet }
ueransim:
  ues:
    - { name: ue1, imsi: "999700000000001", key: ..., opc: ..., sst: 1, dnn: internet }
    - { name: ue2, imsi: "999700000000002", key: ..., opc: ..., sst: 2, dnn: internet }
```

The split has to happen at the SMF: Open5GS selects a UPF inside one SMF by `dnn`, `tac` and
cell id only, not by S-NSSAI (3GPP allows S-NSSAI-based UPF selection, Open5GS does not implement it).

## How addressing works

* Every NF binds `__POD_IP__` (substituted from the downward API at start) and advertises
  its ClusterIP Service FQDN on SBI, so discovery through NRF/SCP returns stable names.
* SMF selection: each per-DNN SMF registers `info.s_nssai[]` (every slice, or only its own `sst`/`sd`) with `dnn = [<dnn>]` in the NRF; the AMF asks the NRF for an SMF serving the requested S-NSSAI + DNN and gets exactly that one.
* PFCP: each SMF talks only to its paired UPF ClusterIP (UDP 8805). The UPF reports its own pod
  IP as the GTP-U endpoint, so the gNB sends N3 traffic straight to the UPF pod.
* N2: the gNB resolves the headless `*-amf-ngap` Service and opens SCTP to the AMF pod,
  avoiding SCTP Service load balancing. UERANSIM 3.3.0 resolves FQDNs itself, so the gNB
  config carries the AMF FQDN. Its bind addresses are the pod IP substituted at start
  (UERANSIM 3.3.0 cannot take an interface name such as `eth0`).
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

## Roaming (SEPP, Home-Routed) with `helm/open5gs-mvno`

`roaming.enabled: true` turns this release into the **Visited PLMN** of one or more home PLMNs
deployed with [`helm/open5gs-mvno`](../open5gs-mvno/README.md) (a full MVNO: AUSF/UDM/UDR/PCF and
H-SMF/H-UPF of PLMN 999/71). Authentication, subscription data and, with Home-Routed roaming, the
PDU session anchor live in the MVNO; this core keeps the RAN, the AMF and the V-SMF/V-UPF.
Nothing changes while `roaming.enabled` is false (the default render is byte-identical).

What the chart adds in roaming mode:

* **SEPP** (`<release>-sepp`): SBI 7777 towards our SCP, N32-c 7778 and N32-f 7779 over HTTPS
  towards each `roaming.peers[].sepp.host`. The Service FQDN is the N32 identity (`sender`), the
  peer lists it as `receiver`, and the TLS certificate must carry it as CN/SAN.
* **3GPP FQDNs**: Open5GS sends a request to the SEPP only when the target apiRoot is
  `<label>.5gc.mnc<MNC>.mcc<MCC>.3gppnetwork.org` of another PLMN. So the NRF (and every SMF, for
  H-SMF callbacks) advertise such names (`advertise: <fqdn>:7777`). Open5GS resolves the `advertise`
  name at startup and the SCP resolves same-PLMN targets, so each of these Services gets a pinned
  ClusterIP (`roaming.fqdnNfs`, `dnns[].clusterIP`) that is injected into every NF pod as
  `hostAliases`. Every such Service also exposes port 80 -> 7777: peers build apiRoots from the
  NF-instance FQDN without a port (`hSmfUri`, the synthesized `nrf.<domain>`), which means port 80.
* **AMF** `access_control` allows the peers' home PLMNs; **PCF** gets a local `policy` for their
  SUPI ranges (no UDR data for them here).
* **UEs**: `ueransim.ues[].hplmn` makes a UE a subscriber of the MVNO (IMSI `99971...`).
  Stock UERANSIM v3.3.0 never selects a PLMN other than its HPLMN; the image built from
  `docker/ueransim` carries patches for that and for the Service Request bug.

### Steps

```bash
# 1. TLS material for both SEPPs (same CA), as Secret "sepp-tls" in each namespace
helm/sepp-certs/make-certs.sh helm/sepp-certs/certs \
  open5gs-sepp.open5gs.svc.cluster.local mvno-sepp.mvno.svc.cluster.local
kubectl create ns mvno
kubectl -n open5gs create secret generic sepp-tls --from-file=ca.crt=helm/sepp-certs/certs/ca.crt \
  --from-file=tls.crt=helm/sepp-certs/certs/open5gs-sepp.open5gs.svc.cluster.local.crt \
  --from-file=tls.key=helm/sepp-certs/certs/open5gs-sepp.open5gs.svc.cluster.local.key
kubectl -n mvno create secret generic sepp-tls --from-file=ca.crt=helm/sepp-certs/certs/ca.crt \
  --from-file=tls.crt=helm/sepp-certs/certs/mvno-sepp.mvno.svc.cluster.local.crt \
  --from-file=tls.key=helm/sepp-certs/certs/mvno-sepp.mvno.svc.cluster.local.key

# 2. Home PLMN
helm upgrade --install mvno ./helm/open5gs-mvno -n mvno

# 3. This chart as Visited PLMN (values-roaming.yaml is an example overlay: pinned ClusterIPs,
#    the roaming UE ue4). Existing NRF/SMF Services must be recreated because clusterIP is immutable.
kubectl -n open5gs delete svc open5gs-nrf open5gs-smf-internet-sst1 open5gs-smf-internet-sst2 open5gs-smf-ims
helm upgrade open5gs ./helm/open5gs -n open5gs -f <your values> -f helm/open5gs/values-roaming.yaml
```

### Verify

```bash
kubectl -n open5gs logs deploy/open5gs-sepp | grep "SEPP established"   # N32-c handshake, both sides
kubectl -n mvno    logs deploy/mvno-sepp    | grep "SEPP established"
kubectl -n open5gs logs deploy/open5gs-amf  | grep -i "Home-Routed Roaming"   # for imsi-99971...
kubectl -n mvno    logs deploy/mvno-smf-internet | grep "UE SUPI"            # IPv4[10.50.x.x]
UE=$(kubectl -n open5gs get pod -l app.kubernetes.io/component=ue-ue4 -o jsonpath='{.items[0].metadata.name}')
kubectl -n open5gs exec $UE -- ip addr show uesimtun0      # 10.50.0.0/16 = anchored in the MVNO UPF
kubectl -n open5gs exec $UE -- ping -I uesimtun0 -c 3 8.8.8.8
```

Known behaviour (Open5GS 2.8.0):

* If the peer SEPP connects before this SEPP has registered with its NRF, the SEPP aborts once with
  `Assertion 'OGS_FSM_STATE(&sepp_node->sm)' failed` and the pod restarts; the handshake then succeeds.
* If the N16 create towards the H-SMF times out, the V-SMF aborts on the UE's retransmission
  (`smf_nsmf_pdusession_build_hsmf_update_data: Assertion 'sess->pdu_session_resource_uri'`). The AMF
  then keeps stale SM contexts and rejects re-registrations with `5GS services not allowed` after a
  404 from the restarted SMF; `kubectl -n open5gs rollout restart deploy/open5gs-amf` clears it.
* UERANSIM's gNB strips the Requested NSSAI from the Registration Request because Open5GS rejects
  it as a non-cleartext IE; the AMF uses the subscribed default S-NSSAI.

## 4G / EPC (`epc.enabled`) with srsRAN_4G

`epc.enabled: true` adds the EPC next to the 5GC, sharing MongoDB, the WebUI and `subscribers[]`
(the HSS reads `slice[0].session[]` as the APN list, so a subscriber with `dnn: internet` has the
APN `internet`). Open5GS' SMF and UPF are also PGW-C and PGW-U: the SMF of the **first `dnns[]`
entry per DNN name** gets `gtpc` (S5/S8-C) and a Gx connection to the PCRF, and the MME maps that
APN to it (`gtpc.client.smf[].apn`). Other entries of the same name stay 5G-only (`dnns[].epc: false`
skips an entry explicitly).

| Interface | Path |
|-----------|------|
| S1-MME | eNB pod -> headless `*-mme-s1ap` (SCTP 36412), resolved to the MME pod IP at start |
| S1-U / S5-U | GTP-U between the eNB pod, the SGW-U pod and the UPF pod (F-TEIDs carry pod IPs) |
| S11 / S5-C | MME -> `*-sgwc` (UDP 2123) -> SMF Service (UDP 2123); follow-ups go to the F-TEID pod IPs |
| Sxa / Sxb | SGW-C -> `*-sgwu` and SMF -> UPF (PFCP, UDP 8805) |
| S6a / Gx | Diameter over **TCP** 3868 (`No_SCTP`) to the HSS / PCRF Services |

Diameter: every node's **Identity is its Service FQDN** (so peers resolve it through cluster DNS,
no `ConnectTo`), the **Realm is the 3GPP one** `epc.mnc<MNC>.mcc<MCC>.3gppnetwork.org`. MME and
SMF list their servers with `ConnectPeer`; the HSS and PCRF accept inbound peers through an
`acl_wl` allow list (own namespace plus `epc.diameter.allowedPeers`).

### srsRAN_4G pods

The ZMQ virtual radio links exactly one `srsenb` to one `srsue`, and after a detach the eNB must be
restarted too, so each `srsran.ues[]` entry is one pod (`lte-<name>`) running both in one container
(ZMQ over localhost). The entrypoint resolves the MME, substitutes the pod IP, starts both and adds
a policy route for the UE address (srsue creates `tun_srsue` but no default route). The liveness
probe restarts the container when no S1 association is ESTABLISHED or the UE never attached;
after an MME pod replacement the pair re-resolves the MME and re-attaches in about 3-4 minutes
(SCTP failure detection plus the probe window). Each pair needs
about 1-2 CPUs at 25 PRB; `srsran.ues[].resources` / `srsran.resources` set requests and limits.
The image comes from `docker/srsran` (GHCR workflow, `ghcr.io/sogaani/srsran-4g`).

### Verify

```bash
kubectl -n open5gs logs deploy/open5gs-mme | grep -i "attach\|S1-Setup"     # eNB S1 setup, UE attach
kubectl -n open5gs logs deploy/open5gs-lte-lte1 | grep -i "attach\|IP:"      # "[ue] Network attach successful. IP: 10.45.x.x"
UE=$(kubectl -n open5gs get pod -l app.kubernetes.io/component=lte-lte1 -o jsonpath='{.items[0].metadata.name}')
kubectl -n open5gs exec $UE -- ip addr show tun_srsue
kubectl -n open5gs exec $UE -- ping -I tun_srsue -c 3 8.8.8.8
```

### 4G roaming to `helm/open5gs-mvno` (S6a + S8 home routed)

With `roaming.peers[].epc.hss` set (see `values-roaming.yaml`), the MME routes S6a for IMSIs of
that PLMN to the home HSS (`hss_map`: Destination-Realm `epc.mnc071.mcc999...`, Destination-Host
`mvno-hss.mvno.svc.cluster.local`) and accepts those IMSIs (`access_control`). The MME has no
PLMN-based PGW selection, so the **home HSS provides the PGW**: the MVNO chart writes the SMF's
pinned ClusterIP into each subscription (`epc.pgwInHss`, MIP6-Agent-Info on S6a) and the SGW-C
opens S8 to it. The UE then gets an address from the MVNO (`10.50.0.0/16`) and its traffic exits
through the MVNO UPF. `values-roaming.yaml` defines `lte4` (IMSI `999710000000002`) for this.

```bash
kubectl -n mvno logs deploy/mvno-hss | grep -i "999710000000002"             # AIR/ULR from open5gs-mme...
kubectl -n mvno logs deploy/mvno-smf-internet | grep "999710000000002"       # S8 Create Session, IPv4[10.50.x.x]
kubectl -n open5gs logs deploy/open5gs-lte-lte4 | grep -i "PLMN\|IP:"        # "Could not find Home PLMN ... trying 999/70", IP 10.50.x.x
```
