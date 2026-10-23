# srsRAN_4G (srsenb + srsue) with the ZMQ virtual radio, for the helm/open5gs
# "srsran" pods (one eNB + UE pair per pod). No srsEPC: Open5GS is the core.
ARG UBUNTU_TAG=24.04

FROM ubuntu:${UBUNTU_TAG} AS build
ARG SRSRAN_VERSION=release_25_10
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates pkg-config \
      libfftw3-dev libmbedtls-dev libboost-program-options-dev \
      libconfig++-dev libsctp-dev libzmq3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 --branch ${SRSRAN_VERSION} https://github.com/srsran/srsRAN_4G.git . \
    && mkdir build && cd build \
    && cmake .. \
         -DCMAKE_BUILD_TYPE=Release \
         -DENABLE_SRSEPC=OFF \
         -DENABLE_GUI=OFF \
         -DENABLE_ZEROMQ=ON \
         -DENABLE_UHD=OFF -DENABLE_BLADERF=OFF -DENABLE_SOAPYSDR=OFF -DENABLE_SKIQ=OFF \
         -DAUTO_DETECT_ISA=OFF \
    && make -j"$(nproc)" srsenb srsue \
    && make install \
    && grep -q "Found libZEROMQ\|ZEROMQ" CMakeCache.txt

FROM ubuntu:${UBUNTU_TAG}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      libfftw3-single3 libmbedtls14t64 libboost-program-options1.83.0 \
      libconfig++9v5 libzmq5 libsctp1 lksctp-tools \
      iproute2 iputils-ping procps ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/srsenb /usr/local/bin/srsue /usr/local/bin/
COPY --from=build /usr/local/lib/libsrsran_rf*.so* /usr/local/lib/
COPY --from=build /usr/local/share/srsran /usr/local/share/srsran
RUN ldconfig && mkdir -p /etc/srsran \
    && for f in /usr/local/share/srsran/*.example; do cp "$f" "/etc/srsran/$(basename "$f" .example)"; done
CMD ["srsenb", "/etc/srsran/enb.conf"]
