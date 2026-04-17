apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: gcp-sm
spec:
  provider:
    gcpsm:
      projectID: ${gcp_project_id}
      auth: {}
