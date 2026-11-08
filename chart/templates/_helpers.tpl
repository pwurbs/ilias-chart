{{- define "ilias.mariadbHost" -}}
{{- printf "%s-mariadb" .Release.Name }}
{{- end }}

{{- define "ilias.secretName" -}}
{{- .Values.secrets.existingSecret | default (printf "%s-secrets" .Release.Name) }}
{{- end }}

{{- define "ilias.secretKeyIliasRootPassword" -}}
{{- .Values.secrets.existingSecretKeys.iliasRootPassword | default "ilias-root-password" }}
{{- end }}

{{- define "ilias.secretKeyIliasDbPassword" -}}
{{- .Values.secrets.existingSecretKeys.iliasDbPassword | default "ilias-db-password" }}
{{- end }}

{{- define "ilias.secretKeyMariadbRootPassword" -}}
{{- .Values.secrets.existingSecretKeys.mariadbRootPassword | default "mariadb-root-password" }}
{{- end }}

{{/*
Pod label and required pod affinity for ilias, ilias-cron and ilias-ilserver: they share the
ReadWriteOnce volumes ilias-public and ilias-data, so they must run on the same node. The first pod
may go to any node, since it matches its own affinity term; all others follow it.
*/}}
{{- define "ilias.sharedVolumesLabel" -}}
ilias-shared-volumes: {{ .Release.Name }}
{{- end }}

{{- define "ilias.sharedVolumesAffinity" -}}
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- include "ilias.sharedVolumesLabel" . | nindent 12 }}
{{- end }}

{{- define "ilias.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
