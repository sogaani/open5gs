{{/* Release-scoped name prefix */}}
{{- define "open5gs.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Common labels */}}
{{- define "open5gs.labels" -}}
app.kubernetes.io/name: open5gs
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Name of a component: (dict "ctx" . "name" "amf") */}}
{{- define "open5gs.component" -}}
{{ include "open5gs.fullname" .ctx }}-{{ .name }}
{{- end -}}

{{/* Cluster-internal FQDN of a component's Service */}}
{{- define "open5gs.fqdn" -}}
{{ include "open5gs.component" . }}.{{ .ctx.Release.Namespace }}.svc.{{ .ctx.Values.clusterDomain }}
{{- end -}}

{{/* Selector labels for a component */}}
{{- define "open5gs.selector" -}}
app.kubernetes.io/name: open5gs
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{/* SBI server block (binds the pod IP, advertises the ClusterIP Service or,
     in roaming mode for the NFs listed in roaming.fqdnNfs / every SMF, the 3GPP FQDN).
     Params: ctx, name, nf (optional, "smf" for per-DNN SMFs) */}}
{{- define "open5gs.sbiServer" -}}
server:
  - address: __POD_IP__
    port: 7777
    advertise: {{ include "open5gs.sbiAdvertise" . }}
{{- end -}}

{{/* ---------------------------------------------------------------------------
     Roaming helpers (all inert unless .Values.roaming.enabled)
     --------------------------------------------------------------------------- */}}

{{/* 3GPP home-network domain, TS 23.003 28.3.2: 5gc.mnc<MNC3>.mcc<MCC3>.3gppnetwork.org
     Params: ctx, optional mcc/mnc (default .Values.plmn) */}}
{{- define "open5gs.plmnDomain" -}}
{{- $mcc := default .ctx.Values.plmn.mcc .mcc -}}
{{- $mnc := default .ctx.Values.plmn.mnc .mnc -}}
{{- printf "5gc.mnc%03d.mcc%03d.3gppnetwork.org" (int $mnc) (int $mcc) -}}
{{- end -}}

{{/* 3GPP FQDN of a component. The label is the component name, so the SCP/SEPP can
     map it back to the Service (<fullname>-<name>) through hostAliases. */}}
{{- define "open5gs.fqdn3gpp" -}}
{{ .name }}.{{ include "open5gs.plmnDomain" (dict "ctx" .ctx) }}
{{- end -}}

{{/* true (non-empty) when roaming is on and this component advertises a 3GPP FQDN */}}
{{- define "open5gs.uses3gppFqdn" -}}
{{- $r := .ctx.Values.roaming | default dict -}}
{{- if and $r.enabled (or (hasKey ($r.fqdnNfs | default dict) .name) (eq (default "" .nf) "smf")) -}}true{{- end -}}
{{- end -}}

{{/* advertise value: "<3gpp fqdn>:7777" in roaming mode (a port-less FQDN would mean 80),
     else the ClusterIP Service FQDN */}}
{{- define "open5gs.sbiAdvertise" -}}
{{- if include "open5gs.uses3gppFqdn" . -}}
{{ include "open5gs.fqdn3gpp" . }}:7777
{{- else -}}
{{ include "open5gs.fqdn" . }}
{{- end -}}
{{- end -}}

{{/* NRF URI used by the SCP (client.nrf) and the NSSF (nsi) */}}
{{- define "open5gs.nrfUri" -}}
http://{{ include "open5gs.sbiAdvertise" (dict "ctx" . "name" "nrf") }}{{ if not (include "open5gs.uses3gppFqdn" (dict "ctx" . "name" "nrf")) }}:7777{{ end }}
{{- end -}}

{{/* Pinned ClusterIP for a component listed in roaming.fqdnNfs ("" otherwise) */}}
{{- define "open5gs.pinnedClusterIP" -}}
{{- $r := .ctx.Values.roaming | default dict -}}
{{- if and $r.enabled (hasKey ($r.fqdnNfs | default dict) .name) -}}{{ index $r.fqdnNfs .name }}{{- end -}}
{{- end -}}

{{/* hostAliases mapping every 3GPP FQDN of this PLMN to its pinned ClusterIP.
     Open5GS resolves `advertise` at startup and the SCP/SEPP resolve Target-apiRoot
     hosts, so every NF pod carries the full list. */}}
{{- define "open5gs.roamingHostAliases" -}}
{{- $r := .Values.roaming -}}
{{- range $nf, $ip := ($r.fqdnNfs | default dict) }}
- ip: {{ $ip | quote }}
  hostnames:
    - {{ include "open5gs.fqdn3gpp" (dict "ctx" $ "name" $nf) }}
{{- end }}
{{- range $d := .Values.dnns }}
{{- $name := include "open5gs.dnnName" (dict "ctx" $ "prefix" "smf" "dnn" $d) }}
{{- if not $d.clusterIP }}
{{- fail (printf "dnns[%s]: clusterIP is required when roaming.enabled (the SMF advertises %s, resolved through hostAliases)" $d.name (include "open5gs.fqdn3gpp" (dict "ctx" $ "name" $name))) }}
{{- end }}
- ip: {{ $d.clusterIP | quote }}
  hostnames:
    - {{ include "open5gs.fqdn3gpp" (dict "ctx" $ "name" $name) }}
{{- end }}
{{- end -}}

{{/* N32 identity of our SEPP (roaming.sepp.sender, default: its Service FQDN) */}}
{{- define "open5gs.seppSender" -}}
{{- default (include "open5gs.fqdn" (dict "ctx" . "name" "sepp")) .Values.roaming.sepp.sender -}}
{{- end -}}

{{/* Name of the Secret holding the SEPP TLS material */}}
{{- define "open5gs.seppTlsSecret" -}}
{{- $t := .Values.roaming.sepp.tls -}}
{{- if $t.cert -}}
{{ include "open5gs.component" (dict "ctx" . "name" "sepp-tls") }}
{{- else -}}
{{ required "roaming.sepp.tls.existingSecret (or tls.ca/cert/key PEM) is required when roaming.enabled" $t.existingSecret }}
{{- end -}}
{{- end -}}

{{/* V-PCF local policy for roaming subscribers: roaming.pcf.policy verbatim, or one
     entry per peer PLMN (all slices, every DNN, QoS 9 / 1 Gbps) */}}
{{- define "open5gs.roamingPcfPolicy" -}}
{{- $r := .Values.roaming -}}
{{- if $r.pcf.policy -}}
{{ toYaml $r.pcf.policy }}
{{- else -}}
{{- $dnnNames := list -}}
{{- range .Values.dnns }}{{ $dnnNames = append $dnnNames .name }}{{ end -}}
{{- $dnnNames = uniq $dnnNames -}}
{{- range $peer := $r.peers }}
{{- $prefix := printf "%s%s" (toString $peer.mcc) (toString $peer.mnc) }}
{{- $n := int (sub 15 (len $prefix)) }}
- supi_range:
    - {{ $prefix }}{{ repeat $n "0" }}-{{ $prefix }}{{ repeat $n "9" }}
  slice:
    {{- range $.Values.slices }}
    - sst: {{ .sst }}
      {{- if .sd }}
      sd: {{ .sd | quote }}
      {{- end }}
      default_indicator: true
      session:
        {{- range $dnnNames }}
        - name: {{ . }}
          type: 3
          ambr:
            downlink: { value: 1, unit: 3 }
            uplink: { value: 1, unit: 3 }
          qos:
            index: 9
            arp:
              priority_level: 8
              pre_emption_vulnerability: 1
              pre_emption_capability: 1
        {{- end }}
    {{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{/* SBI client block pointing at the SCP */}}
{{- define "open5gs.sbiClientScp" -}}
client:
  scp:
    - uri: http://{{ include "open5gs.fqdn" (dict "ctx" .ctx "name" "scp") }}:7777
{{- end -}}

{{/* logger / global header shared by every NF config */}}
{{- define "open5gs.configHeader" -}}
logger:
  level: {{ .Values.logLevel }}
global:
  max:
    ue: 1024
{{- end -}}

{{/* MongoDB URI */}}
{{- define "open5gs.mongoUri" -}}
mongodb://{{ include "open5gs.fqdn" (dict "ctx" . "name" "mongodb") }}:27017/open5gs
{{- end -}}

{{/* plmn_id mapping */}}
{{- define "open5gs.plmnId" -}}
plmn_id:
  mcc: {{ .Values.plmn.mcc | quote }}
  mnc: {{ .Values.plmn.mnc | quote }}
{{- end -}}

{{/* s_nssai list from .Values.slices */}}
{{- define "open5gs.snssaiList" -}}
{{- range .Values.slices }}
- sst: {{ .sst }}
{{- if .sd }}
  sd: {{ .sd | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Resource name of a per-DNN NF: (dict "ctx" . "prefix" "smf" "dnn" <dnns[] entry>)
  smf-<dnn>                  when the entry has no sst
  smf-<dnn>-sst<N>           when the entry has sst
  smf-<dnn>-sst<N>-sd<hex>   when the entry has sst and sd
*/}}
{{- define "open5gs.dnnName" -}}
{{- $d := .dnn -}}
{{- if hasKey $d "sst" -}}
{{- if $d.sd -}}
{{ printf "%s-%s-sst%d-sd%s" .prefix $d.name (int $d.sst) (lower (toString $d.sd)) }}
{{- else -}}
{{ printf "%s-%s-sst%d" .prefix $d.name (int $d.sst) }}
{{- end -}}
{{- else -}}
{{ printf "%s-%s" .prefix $d.name }}
{{- end -}}
{{- end -}}

{{/*
S-NSSAIs a per-DNN SMF advertises in SmfInfo: (dict "ctx" . "dnn" <dnns[] entry>)
  the entry's own sst/sd when set (must be one of .Values.slices), else every slice.
Rendered as YAML list items "- sst: N" / "  sd: ..." for use under info.s_nssai.
*/}}
{{- define "open5gs.dnnSlices" -}}
{{- $d := .dnn -}}
{{- if hasKey $d "sst" -}}
{{- $found := false -}}
{{- range .ctx.Values.slices -}}
{{- if and (eq (int .sst) (int $d.sst)) (eq (toString (default "" .sd)) (toString (default "" $d.sd))) -}}
{{- $found = true -}}
{{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail (printf "dnns[%s]: sst %v sd %q is not listed in .Values.slices (the AMF would reject it)" $d.name $d.sst (toString (default "" $d.sd))) -}}
{{- end }}
- sst: {{ int $d.sst }}
{{- if $d.sd }}
  sd: {{ toString $d.sd | quote }}
{{- end }}
{{- else -}}
{{- range .ctx.Values.slices }}
- sst: {{ .sst }}
{{- if .sd }}
  sd: {{ .sd | quote }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{/* Shell wrapper that substitutes the pod IP into the config and execs the NF */}}
{{- define "open5gs.nfCommand" -}}
{{- $nf := default .name .nf -}}
command: ["/bin/sh", "-c"]
args:
  - |
    set -e
    sed "s/__POD_IP__/${POD_IP}/g" /config/{{ $nf }}.yaml > /tmp/{{ $nf }}.yaml
    exec open5gs-{{ $nf }}d -c /tmp/{{ $nf }}.yaml
{{- end -}}

{{/* POD_IP env from the downward API */}}
{{- define "open5gs.podIpEnv" -}}
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
{{- end -}}

{{/* Standard NF Deployment.
     Params: ctx, name, extraPorts (list of {name,port,protocol}),
             nf (binary/config name, defaults to name),
             configPath (template path used for the checksum, defaults to /<name>/configmap.yaml),
             nodeSelector (optional map), extraVolumeMounts / extraVolumes (optional lists) */}}
{{- define "open5gs.nfDeployment" -}}
{{- $name := .name -}}
{{- $ctx := .ctx -}}
{{- $nf := default .name .nf -}}
{{- $configPath := default (printf "/%s/configmap.yaml" $name) .configPath -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "open5gs.component" . }}
  labels:
    {{- include "open5gs.labels" $ctx | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  replicas: 1
  selector:
    matchLabels:
      {{- include "open5gs.selector" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "open5gs.selector" . | nindent 8 }}
      annotations:
        checksum/config: {{ include (print $ctx.Template.BasePath $configPath) $ctx | sha256sum }}
    spec:
      {{- with $ctx.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if ($ctx.Values.roaming | default dict).enabled }}
      hostAliases:
        {{- include "open5gs.roamingHostAliases" $ctx | trim | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ $nf }}
          image: "{{ $ctx.Values.image.repository }}:{{ $ctx.Values.image.tag }}"
          imagePullPolicy: {{ $ctx.Values.image.pullPolicy }}
          {{- include "open5gs.nfCommand" . | nindent 10 }}
          env:
            {{- include "open5gs.podIpEnv" . | nindent 12 }}
          ports:
            - name: sbi
              containerPort: 7777
              protocol: TCP
            {{- range .extraPorts }}
            - name: {{ .name }}
              containerPort: {{ .port }}
              protocol: {{ .protocol }}
            {{- end }}
          readinessProbe:
            tcpSocket:
              port: 7777
            initialDelaySeconds: 3
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /config
            {{- with .extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          resources:
            {{- toYaml $ctx.Values.resources | nindent 12 }}
      volumes:
        - name: config
          configMap:
            name: {{ include "open5gs.component" . }}
        {{- with .extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
{{- end -}}

{{/* Standard ClusterIP Service for an NF's SBI port.
     Params: ctx, name, extraPorts (list of {name,port,protocol[,targetPort]}),
             nf (optional, "smf" for per-DNN SMFs),
             clusterIP (optional; defaults to the pinned roaming ClusterIP, if any).
     An NF that advertises a 3GPP FQDN also gets port 80 -> 7777: peers build
     apiRoots from the NF-instance FQDN without a port (e.g. hSmfUri, nrf.<domain>),
     which Open5GS/curl turn into port 80. */}}
{{- define "open5gs.nfService" -}}
{{- $clusterIP := default (include "open5gs.pinnedClusterIP" .) .clusterIP -}}
{{- $extraPorts := .extraPorts | default list -}}
{{- if include "open5gs.uses3gppFqdn" . -}}
{{- $extraPorts = append $extraPorts (dict "name" "http" "port" 80 "targetPort" 7777 "protocol" "TCP") -}}
{{- end -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "open5gs.component" . }}
  labels:
    {{- include "open5gs.labels" .ctx | nindent 4 }}
    app.kubernetes.io/component: {{ .name }}
spec:
  type: ClusterIP
  {{- with $clusterIP }}
  clusterIP: {{ . }}
  {{- end }}
  selector:
    {{- include "open5gs.selector" . | nindent 4 }}
  ports:
    - name: sbi
      port: 7777
      targetPort: 7777
      protocol: TCP
    {{- range $extraPorts }}
    - name: {{ .name }}
      port: {{ .port }}
      targetPort: {{ .targetPort | default .port }}
      protocol: {{ .protocol }}
    {{- end }}
{{- end -}}
