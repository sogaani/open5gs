# open5gs-mvno

Home PLMN of a **full MVNO** (default 999/71) built from Open5GS: NRF, SCP, SEPP, AUSF, UDM, UDR,
PCF, BSF, NSSF, one H-SMF/H-UPF pair per `dnns[]` entry, MongoDB, WebUI and a subscriber Job.
There is no AMF and no RAN: MVNO subscribers attach through the MNO core deployed with
[`helm/open5gs`](../open5gs/README.md) (`roaming.enabled: true`), which reaches this core over
SEPP / N32. With Home-Routed roaming (the default, `lbo_roaming_allowed` unset) the PDU session is
anchored here and the UE gets an address from `dnns[].subnet` (10.50.0.0/16).

| Component | Role |
|-----------|------|
| mvno-sepp | N32-c :7778 / N32-f :7779 (HTTPS) to the MNO SEPP; SBI :7777 to the local SCP |
| mvno-nrf, -ausf, -udm, -nssf, mvno-smf-\<dnn\> | advertise `<name>.5gc.mnc071.mcc999.3gppnetwork.org:7777` on pinned ClusterIPs (`roaming.fqdnNfs`, `dnns[].clusterIP`); each Service also maps :80 to 7777 (peers use port-less apiRoots such as `hSmfUri`) |
| mvno-upf-\<dnn\> | H-UPF: N9 GTP-U from the MNO V-UPF arrives on the pod IP; UE traffic is NATed to the pod IP |
| mvno-webui | subscriber management, LoadBalancer `172.31.254.21:9999`, admin / 1423 |
| mvno-hss, mvno-pcrf (`epc.enabled`, default on) | 4G home HSS (S6a from the visited MME) and PCRF (Gx from the PGW-C); Diameter over TCP 3868, identity = Service FQDN, realm `epc.mnc071.mcc999.3gppnetwork.org` |
| mvno-smf-\<dnn\> as PGW-C | also listens on GTP-C 2123/UDP; its pinned ClusterIP is the S8 PGW address the HSS sends to the MME (`epc.pgwInHss`) |

## Install

```bash
helm/sepp-certs/make-certs.sh helm/sepp-certs/certs \
  open5gs-sepp.open5gs.svc.cluster.local mvno-sepp.mvno.svc.cluster.local
kubectl create ns mvno
kubectl -n mvno create secret generic sepp-tls --from-file=ca.crt=helm/sepp-certs/certs/ca.crt \
  --from-file=tls.crt=helm/sepp-certs/certs/mvno-sepp.mvno.svc.cluster.local.crt \
  --from-file=tls.key=helm/sepp-certs/certs/mvno-sepp.mvno.svc.cluster.local.key
helm upgrade --install mvno ./helm/open5gs-mvno -n mvno
```

Then enable roaming on the MNO release (see the MNO README, "Roaming"). The roaming UE is
defined there (`ueransim.ues[].hplmn: {mcc: "999", mnc: "71"}`, IMSI from `subscribers[]` here).

## Values

Same layout as `helm/open5gs` without `amf`, `tac` and `ueransim`:

| Key | Default | Notes |
|-----|---------|-------|
| `plmn` | 999 / 71 | Must differ from the MNO's PLMN |
| `dnns[]` | `internet` 10.50.0.0/16, clusterIP 192.96.0.54 | DNN names must also exist in the visited PLMN (the V-SMF is chosen by S-NSSAI + DNN); `clusterIP` is required |
| `subscribers[]` | IMSI 999710000000001 | Inserted into the MVNO MongoDB; HR roaming unless `lbo_roaming_allowed` is set in the DB |
| `roaming.fqdnNfs` | nrf .50, ausf .51, udm .52, nssf .53 | Pinned ClusterIPs for the 3GPP FQDNs |
| `roaming.peers[]` | `open5gs-sepp.open5gs.svc.cluster.local` 7778/7779 | The MNO SEPP (PLMN 999/70) |
| `roaming.sepp.tls.existingSecret` | `sepp-tls` | Secret with `ca.crt`, `tls.crt`, `tls.key` (or pass `tls.ca/cert/key` PEM) |
| `webui.service.loadBalancerIP` | 172.31.254.21 | |
| `epc.enabled` | `true` | Deploy HSS and PCRF; the SMF/UPF double as PGW-C/PGW-U |
| `epc.pgwInHss` | `true` | Write `session.smf.ipv4 = dnns[].clusterIP` into every subscriber (the visited MME learns the home PGW from the HSS) |
| `epc.diameter.allowedPeers` | `["*.open5gs.svc.cluster.local"]` | Inbound Diameter peers accepted by the HSS/PCRF (the visited MME's identity is `open5gs-mme.open5gs.svc.cluster.local`) |

## 4G (S6a / S8 home routed)

A 4G USIM of this PLMN on an MNO eNB (`helm/open5gs` with `epc.enabled`, `srsran.ues[]` entry
`lte4`, `roaming.peers[].epc.hss: mvno-hss.mvno.svc.cluster.local`) is served as follows:

1. The visited MME matches the IMSI prefix in its `hss_map` and sends AIR/ULR with
   Destination-Realm `epc.mnc071.mcc999.3gppnetwork.org` / Destination-Host `mvno-hss...`
   (TCP to the `mvno-hss` Service; accepted through the acl_wl allow list).
2. The ULA carries the APN list from `subscribers[]` and, per APN, the PGW address
   (`session.smf.ipv4`, MIP6-Agent-Info) = the ClusterIP of `mvno-smf-<dnn>`.
3. The visited SGW-C opens S8 (GTP-C 2123) to that address; the H-SMF does Gx with `mvno-pcrf`
   (subscriber in the MVNO MongoDB) and Sxb with `mvno-upf-<dnn>`.
4. S8-U runs between the visited SGW-U pod and the `mvno-upf` pod; the UE gets `10.50.x.x`.

## Keeping the templates in sync

`templates/` and `_helpers.tpl` are copies of the MNO chart (minus `amf/`, `ueransim/`, `mme/`, `sgwc/`, `sgwu/` and `srsran/`), with
`app.kubernetes.io/name: open5gs-mvno`. Check for drift with:

```bash
diff -r helm/open5gs/templates helm/open5gs-mvno/templates | grep -v "Only in helm/open5gs/templates"
```
