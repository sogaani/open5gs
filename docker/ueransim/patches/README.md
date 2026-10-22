# UERANSIM v3.3.0 patches

Applied with `git apply` while building `docker/ueransim/Dockerfile`.

| Patch | Why |
|---|---|
| `0001-ue-select-other-plmns.patch` | `performPlmnSelection()` only accepted the HPLMN or an equivalent PLMN, so a UE could never camp on a visited PLMN. Adds the TS 23.122 automatic-mode step that selects any other non-forbidden PLMN. Needed for the roaming (MVNO) setup. |
| `0002-gnb-select-amf-without-requested-slice.patch` | v3.3.0 selects the AMF by the Requested NSSAI of the Registration Request. Any other initial NAS message (Service Request after CM-IDLE, gNB restart, Deregistration) has no slice, so `selectAmf()` failed with "Could not find a suitable AMF" and the UE never recovered. Falls back to any connected AMF. |
| `0003-gnb-guard-requested-nssai.patch` | The same code dereferenced the Requested NSSAI IE even when the Registration Request had none (undefined behaviour). It still strips the IE before forwarding: Open5GS rejects an Initial UE Message whose Registration Request carries non-cleartext IEs such as the Requested NSSAI (`Non cleartext IEs is included`, TS 24.501 4.4.6), so the AMF then relies on the subscribed default S-NSSAIs. |
