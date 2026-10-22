# UERANSIM v3.3.0 patches

Applied with `git apply` while building `docker/ueransim/Dockerfile`.

| Patch | Why |
|---|---|
| `0001-ue-select-other-plmns.patch` | `performPlmnSelection()` only accepted the HPLMN or an equivalent PLMN, so a UE could never camp on a visited PLMN. Adds the TS 23.122 automatic-mode step that selects any other non-forbidden PLMN. Needed for the roaming (MVNO) setup. |
| `0002-gnb-select-amf-without-requested-slice.patch` | v3.3.0 selects the AMF by the Requested NSSAI of the Registration Request. Any other initial NAS message (Service Request after CM-IDLE, gNB restart, Deregistration) has no slice, so `selectAmf()` failed with "Could not find a suitable AMF" and the UE never recovered. Falls back to any connected AMF. |
| `0003-gnb-keep-requested-nssai.patch` | The same code stripped the Requested NSSAI from the Registration Request before forwarding it to the AMF, and dereferenced the IE when it was absent. The PDU is now forwarded unmodified. |
