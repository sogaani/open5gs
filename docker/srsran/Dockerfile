# srsRAN_4G (srsenb + srsue) with the ZMQ virtual radio, for the helm/open5gs
# "srsran" pods (one eNB + UE pair per pod). No srsEPC: Open5GS is the core.
ARG UBUNTU_TAG=24.04

FROM ubuntu:${UBUNTU_TAG} AS build
ARG SRSRAN_VERSION=release_25_10
# x86: build for a fixed, portable ISA level instead of -march=native of the CI
# runner (AVX512 there would crash on the cluster nodes). x86-64-v3 = AVX2/FMA.
# arm64: NEON is implied by the architecture.
ARG TARGETARCH
ARG X86_ISA_FLAGS="-DGCC_ARCH=x86-64-v3 -DHAVE_SSE=ON -DHAVE_AVX=ON -DHAVE_AVX2=ON -DHAVE_FMA=ON"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates pkg-config \
      libfftw3-dev libmbedtls-dev libboost-program-options-dev \
      libconfig++-dev libsctp-dev libzmq3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 --branch ${SRSRAN_VERSION} https://github.com/srsran/srsRAN_4G.git . \
    && mkdir build && cd build \
    && if [ "${TARGETARCH:-$(dpkg --print-architecture)}" = "amd64" ]; then ISA_FLAGS="${X86_ISA_FLAGS}"; else ISA_FLAGS=""; fi \
    && cmake .. ${ISA_FLAGS} \
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
