{{/* Common name + labels */}}
{{- define "holmes-sre.name" -}}holmes-investigator{{- end -}}

{{- define "holmes-sre.labels" -}}
app.kubernetes.io/name: {{ include "holmes-sre.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Prometheus query URL. Use the explicit override if set, otherwise point at the
kube-prometheus-stack service in the release namespace.
*/}}
{{- define "holmes-sre.prometheusUrl" -}}
{{- if .Values.toolsets.prometheus.url -}}
{{ .Values.toolsets.prometheus.url }}
{{- else -}}
http://{{ .Release.Name }}-kube-prometheus-stack-prometheus.{{ .Release.Namespace }}.svc.cluster.local:9090
{{- end -}}
{{- end -}}

{{/*
ArgoCD server (host:port, no scheme). Override if set, else the argo-cd
subchart service in the release namespace.
*/}}
{{- define "holmes-sre.argocdServer" -}}
{{- if .Values.toolsets.argocd.server -}}
{{ .Values.toolsets.argocd.server }}
{{- else -}}
{{ .Release.Name }}-argocd-server.{{ .Release.Namespace }}.svc.cluster.local:443
{{- end -}}
{{- end -}}
