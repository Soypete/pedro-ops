# vLLM CPU Embeddings Server

This document describes the CPU-based embeddings server deployment using vLLM.

## Overview

The embeddings server runs as a Kubernetes Deployment in the pedro-bots helm chart, providing embeddings for the mempalace service. It uses the official vLLM CPU image from AWS ECR Public.

**Reference**: [vLLM K8s CPU Deployment](https://docs.vllm.ai/en/stable/deployment/k8s/)

## Docker Image

```dockerfile
FROM public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest

RUN mkdir -p /models

EXPOSE 8081

CMD ["vllm", "serve", "nomic-ai/nomic-embed-text-v1.5", "--trust-remote-code", "--port", "8081"]
```

Build and push:
```bash
docker build -f cli/embeddings/Dockerfile -t 100.81.89.62:5000/pedro-embeddings:latest .
podman push 100.81.89.62:5000/pedro-embeddings:latest
```

## Helm Configuration

The embeddings deployment is defined in `charts/pedro-bots/templates/embeddings-deployment.yaml`:

```yaml
embeddings:
  enabled: true
  image:
    repository: 100.81.89.62:5000/pedro-embeddings
    tag: latest
  model: "nomic-ai/nomic-embed-text-v1.5"
  hfTokenSecret: "hf-token-secret"
  resources:
    limits:
      cpu: "4"
      memory: 8Gi
    requests:
      cpu: "2"
      memory: 4Gi
```

## Required Secrets

Create a Kubernetes Secret for Hugging Face access (for gated models):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hf-token-secret
type: Opaque
stringData:
  token: "REPLACE_WITH_HF_TOKEN"
```

## Deployment

```bash
helm upgrade --install pedro-bots charts/pedro-bots -n chatbot
```

## Testing

```bash
# Get the service endpoint
kubectl get svc -n chatbot | grep embeddings

# Test embeddings endpoint
curl http://pedro-embeddings.chatbot.svc.cluster.local:8081/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "nomic-ai/nomic-embed-text-v1.5", "input": "Hello world"}'
```

## Mempalace Integration

The mempalace deployment connects to embeddings via:

```yaml
env:
  - name: EMBEDDING_LLM_PATH
    value: "http://pedro-embeddings.chatbot.svc.cluster.local:8081"
  - name: EMBEDDING_MODEL
    value: "nomic-embed-text"
```

Note: The endpoint path does NOT include `/v1` because vLLM serves embeddings at `/v1/embeddings` directly.

## Troubleshooting

- **Startup time**: vLLM CPU takes ~60s to load the model. Probes are configured with `initialDelaySeconds: 60`
- **Model download**: First deployment will download the model from Hugging Face (~500MB)
- **Resource limits**: CPU embeddings are slow; adjust resources based on latency requirements