#!/bin/sh
# Generate a test CA and one server/client certificate per SEPP for N32 TLS.
#
#   make-certs.sh <outdir> <sepp-fqdn> [<sepp-fqdn> ...]
#
# Each certificate's CN and SAN is the SEPP's Service FQDN, which the peer uses as
# the N32 URI host and as the N32 "receiver" identity, e.g.
#   make-certs.sh certs open5gs-sepp.open5gs.svc.cluster.local mvno-sepp.mvno.svc.cluster.local
# Both charts must trust the same ca.crt.
set -eu

if [ $# -lt 2 ]; then
  echo "usage: $0 <outdir> <sepp-fqdn> [<sepp-fqdn> ...]" >&2
  exit 1
fi

out=$1; shift
mkdir -p "$out"
days=3650

if [ ! -f "$out/ca.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days "$days" \
    -subj "/CN=sepp-ca" -keyout "$out/ca.key" -out "$out/ca.crt" 2>/dev/null
  echo "created $out/ca.crt"
fi

for fqdn in "$@"; do
  ext="$out/$fqdn.ext"
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth,clientAuth\nbasicConstraints=CA:FALSE\n' "$fqdn" > "$ext"
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$fqdn" \
    -keyout "$out/$fqdn.key" -out "$out/$fqdn.csr" 2>/dev/null
  openssl x509 -req -in "$out/$fqdn.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial \
    -days "$days" -extfile "$ext" -out "$out/$fqdn.crt" 2>/dev/null
  rm -f "$out/$fqdn.csr" "$ext"
  echo "created $out/$fqdn.crt / .key"
done

cat <<MSG

Create the Secret each chart expects (roaming.sepp.tls.existingSecret, default "sepp-tls"):
MSG
for fqdn in "$@"; do
  ns=$(printf '%s' "$fqdn" | cut -d. -f2)
  cat <<MSG
  kubectl -n $ns create secret generic sepp-tls \\
    --from-file=ca.crt=$out/ca.crt --from-file=tls.crt=$out/$fqdn.crt --from-file=tls.key=$out/$fqdn.key
MSG
done
cat <<MSG

or pass the PEMs to helm instead:
  --set-file roaming.sepp.tls.ca=$out/ca.crt --set-file roaming.sepp.tls.cert=$out/<fqdn>.crt --set-file roaming.sepp.tls.key=$out/<fqdn>.key
MSG
