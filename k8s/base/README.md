# Base Kubernetes Manifests

This directory contains base Kubernetes manifests that are common across all environments.

## Contents

- `namespace.yaml` - Creates the `pedro-ops` namespace
- `kustomization.yaml` - Kustomize configuration for base resources

## Usage

Apply base manifests directly:

```bash
kubectl apply -k k8s/base
```

Or reference from overlays:

```yaml
# k8s/overlays/production/kustomization.yaml
bases:
  - ../../base
```

## Adding New Resources

1. Create YAML manifest file in this directory
2. Add resource to `kustomization.yaml`:

```yaml
resources:
  - namespace.yaml
  - your-new-resource.yaml
```

3. Test the build:

```bash
kubectl kustomize k8s/base
```

## Conventions

- Use declarative YAML manifests
- Follow Kubernetes naming conventions (kebab-case)
- Add labels for proper resource management
- Include comments for complex configurations
