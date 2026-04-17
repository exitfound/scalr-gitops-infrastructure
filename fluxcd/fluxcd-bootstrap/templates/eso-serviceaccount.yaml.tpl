apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: external-secrets
  annotations:
    iam.gke.io/gcp-service-account: ${gsa_email}
