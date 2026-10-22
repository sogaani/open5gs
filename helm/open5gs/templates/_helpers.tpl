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

{{/* SBI server block (binds the pod IP, advertises the ClusterIP Service) */}}
{{- define "open5gs.sbiServer" -}}
server:
  - address: __POD_IP__
    port: 7777
    advertise: {{ include "open5gs.fqdn" . }}
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
             nodeSelector (optional map) */}}
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
          resources:
            {{- toYaml $ctx.Values.resources | nindent 12 }}
      volumes:
        - name: config
          configMap:
            name: {{ include "open5gs.component" . }}
{{- end -}}

{{/* Standard ClusterIP Service for an NF's SBI port. Params: ctx, name, extraPorts */}}
{{- define "open5gs.nfService" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "open5gs.component" . }}
  labels:
    {{- include "open5gs.labels" .ctx | nindent 4 }}
    app.kubernetes.io/component: {{ .name }}
spec:
  type: ClusterIP
  selector:
    {{- include "open5gs.selector" . | nindent 4 }}
  ports:
    - name: sbi
      port: 7777
      targetPort: 7777
      protocol: TCP
    {{- range .extraPorts }}
    - name: {{ .name }}
      port: {{ .port }}
      targetPort: {{ .port }}
      protocol: {{ .protocol }}
    {{- end }}
{{- end -}}
