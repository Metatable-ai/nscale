{{- define "nscale.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "nscale.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "nscale.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "nscale.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "nscale.labels" -}}
helm.sh/chart: {{ include "nscale.chart" . }}
{{ include "nscale.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "nscale.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nscale.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "nscale.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "nscale.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "nscale.proxyServiceName" -}}
{{- printf "%s-proxy" (include "nscale.fullname" .) -}}
{{- end -}}

{{- define "nscale.adminServiceName" -}}
{{- printf "%s-admin" (include "nscale.fullname" .) -}}
{{- end -}}

{{- define "nscale.redisFullname" -}}
{{- printf "%s-redis" (include "nscale.fullname" .) -}}
{{- end -}}

{{- define "nscale.redisConfigMapName" -}}
{{- printf "%s-config" (include "nscale.redisFullname" .) -}}
{{- end -}}

{{- define "nscale.redisPvcName" -}}
{{- printf "%s-data" (include "nscale.redisFullname" .) -}}
{{- end -}}

{{- define "nscale.redisServiceName" -}}
{{- include "nscale.redisFullname" . -}}
{{- end -}}

{{- define "nscale.redisUrl" -}}
{{- if .Values.redis.enabled -}}
{{- printf "redis://%s:%d" (include "nscale.redisServiceName" .) (int .Values.redis.service.port) -}}
{{- else -}}
{{- .Values.redis.externalUrl -}}
{{- end -}}
{{- end -}}

{{- define "nscale.etcdServiceName" -}}
{{- printf "%s-etcd" (include "nscale.fullname" .) -}}
{{- end -}}

{{- define "nscale.etcdEndpoints" -}}
{{- if .Values.etcd.enabled -}}
{{- $service := include "nscale.etcdServiceName" . -}}
{{- $namespace := .Release.Namespace -}}
{{- $port := int .Values.etcd.service.clientPort -}}
{{- $endpoints := list -}}
{{- range $i, $_ := until (int .Values.etcd.replicaCount) -}}
{{- $endpoints = append $endpoints (printf "http://%s-%d.%s.%s.svc.cluster.local:%d" $service $i $service $namespace $port) -}}
{{- end -}}
{{ join "," $endpoints }}
{{- else -}}
{{- .Values.etcd.externalEndpoints -}}
{{- end -}}
{{- end -}}

{{- define "nscale.etcdInitialCluster" -}}
{{- $service := include "nscale.etcdServiceName" . -}}
{{- $namespace := .Release.Namespace -}}
{{- $port := int .Values.etcd.service.peerPort -}}
{{- $members := list -}}
{{- range $i, $_ := until (int .Values.etcd.replicaCount) -}}
{{- $members = append $members (printf "%s-%d=http://%s-%d.%s.%s.svc.cluster.local:%d" $service $i $service $i $service $namespace $port) -}}
{{- end -}}
{{ join "," $members }}
{{- end -}}

{{- define "nscale.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else if .Values.secrets.name -}}
{{- .Values.secrets.name -}}
{{- else -}}
{{- printf "%s-secrets" (include "nscale.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "nscale.configListenAddr" -}}
{{- default (printf "0.0.0.0:%d" (int .Values.ports.proxy)) .Values.config.listenAddr -}}
{{- end -}}

{{- define "nscale.configAdminAddr" -}}
{{- default (printf "0.0.0.0:%d" (int .Values.ports.admin)) .Values.config.adminAddr -}}
{{- end -}}
