apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${ksa}
  namespace: ${namespace}
  annotations:
    iam.gke.io/gcp-service-account: ${gsa_email}
