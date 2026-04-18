apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-external-secrets
  namespace: flux-system
spec:
  interval: 10m
  path: ./fluxcd/infrastructure/external-secrets
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-external-secrets-config
  namespace: flux-system
spec:
  interval: 10m
  path: ./fluxcd/infrastructure/external-secrets-config
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure-external-secrets
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-scalr-agent-dev
  namespace: flux-system
spec:
  interval: 10m
  path: ./fluxcd/infrastructure/scalr-agent-dev
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure-external-secrets-config
