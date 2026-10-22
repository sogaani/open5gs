# UERANSIM gNB / UE simulator (https://github.com/aligungr/UERANSIM)
ARG UERANSIM_VERSION=v3.3.0
ARG UBUNTU_TAG=26.04

FROM ubuntu:${UBUNTU_TAG} AS build
ARG UERANSIM_VERSION
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates git make gcc g++ cmake libsctp-dev lksctp-tools && \
    rm -rf /var/lib/apt/lists/*
# Local fixes on top of the release (see patches/README.md):
#   0001 UE: also select non-forbidden visited PLMNs (roaming)
#   0002 gNB: Service Request / non-registration initial NAS reached no AMF
#   0003 gNB: do not dereference an absent Requested NSSAI
COPY patches/ /patches/
RUN git clone --depth 1 --branch ${UERANSIM_VERSION} https://github.com/aligungr/UERANSIM.git /UERANSIM && \
    cd /UERANSIM && \
    for p in /patches/*.patch; do echo "applying $p" && git apply --verbose "$p"; done && \
    make -j"$(nproc)"

FROM ubuntu:${UBUNTU_TAG}
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libsctp1 lksctp-tools iproute2 iputils-ping curl ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    # nr-ue opens /etc/iproute2/rt_tables (hard-coded), but iproute2 on Ubuntu
    # 24.04+ ships the file under /usr/share/iproute2. Provide the legacy path.
    mkdir -p /etc/iproute2 && \
    if [ ! -f /etc/iproute2/rt_tables ]; then cp /usr/share/iproute2/rt_tables /etc/iproute2/rt_tables; fi
COPY --from=build /UERANSIM/build/nr-gnb /UERANSIM/build/nr-ue /UERANSIM/build/nr-cli \
                  /UERANSIM/build/nr-binder /UERANSIM/build/libdevbnd.so /usr/local/bin/
COPY --from=build /UERANSIM/config /etc/ueransim
WORKDIR /etc/ueransim
CMD ["nr-gnb", "-c", "/etc/ueransim/open5gs-gnb.yaml"]
