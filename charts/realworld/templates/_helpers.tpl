{{- define "realworld.labels" -}}
app.kubernetes.io/part-of: realworld
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "realworld.selector" -}}
app.kubernetes.io/name: {{ . }}
app.kubernetes.io/part-of: realworld
{{- end }}

{{/* Restricted Pod Security Standard, shared by both containers. */}}
{{- define "realworld.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/* Spread replicas across AZs and nodes so one failure doesn't take the tier down. */}}
{{- define "realworld.spread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        {{- include "realworld.selector" . | nindent 8 }}
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        {{- include "realworld.selector" . | nindent 8 }}
{{- end }}
