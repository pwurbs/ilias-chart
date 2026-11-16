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

{{- define "ilias.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
