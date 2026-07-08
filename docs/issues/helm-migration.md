# Migrate k8s manifests to Helm charts

## Problem

The pedro-ops repository currently uses a mix of Kustomize (`k8s/`) and Helm (`helm/`), leading to inconsistency in how applications are deployed.

## Current State

- `k8s/base/` - Uses Kustomize for base manifests
- `helm/` - Contains some Helm charts (tailscale-ingresses, eleduck-analytics)
- Applications like embed-server are being added as Helm charts while others remain as Kustomize

## Goal

Migrate all cluster applications to Helm charts, deployed via Foundry CLI or skaffold.

## Benefits

1. **Consistency** - Single deployment mechanism for all applications
2. **Flexibility** - Helm values allow environment-specific overrides
3. **Reusability** - Helm charts can be shared or published
4. **Foundry/skaffold integration** - Both tools work well with Helm

## Scope

### Phase 1: Document current deployment methods
- [ ] List all current deployments and their methods (kustomize, helm, direct kubectl)
- [ ] Identify which k8s manifests should become Helm charts

### Phase 2: Migrate k8s/base/ to Helm
- [ ] Convert namespace.yaml to Helm template (or keep as is)
- [ ] Move each application from k8s/base/<app>/ to helm/<app>/
- [ ] Update kustomization.yaml to remove migrated resources

### Phase 3: Update deployment workflow
- [ ] Update Foundry config to use Helm charts
- [ ] Or configure skaffold for local development
- [ ] Document deployment process

### Phase 4: Deprecate k8s/ directory
- [ ] Remove k8s/base/ once all applications are migrated
- [ ] Update CLAUDE.md with new deployment instructions

## Example

Before (Kustomize):
```yaml
# k8s/base/myapp/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
```

After (Helm):
```yaml
# helm/myapp/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "myapp.fullname" . }}
```

## Priority

1. **High**: Migrate applications that need frequent updates (bot services)
2. **Medium**: Migrate infrastructure components (monitoring, networking)
3. **Low**: Migrate one-off resources

## Notes

- The embed-server chart (helm/pedro-embed-server/) is an example of the target format
- Consider using Helmfile for managing multiple charts if needed
- Keep production overrides in a separate values file or overlay