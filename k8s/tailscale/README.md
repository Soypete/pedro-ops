# Tailscale Integration

This directory contains Kubernetes manifests for integrating Tailscale into the pedro-ops cluster.

## Overview

Tailscale provides secure connectivity between the Kubernetes cluster and external resources (e.g., GPU inference machine) via WireGuard VPN.

## Components

- **Tailscale Operator**: Manages Tailscale integration in Kubernetes
- **Connector**: Exposes cluster to Tailscale network and routes traffic to external machines
- **DNS Config**: Integrates Tailscale Magic DNS with cluster DNS

## Prerequisites

1. Tailscale account (free tier works fine)
2. OAuth credentials from Tailscale admin console

## Setup Instructions

### 1. Create OAuth Credentials

1. Go to [Tailscale OAuth settings](https://login.tailscale.com/admin/settings/oauth)
2. Click "Generate OAuth Client"
3. Copy the Client ID and Client Secret

### 2. Configure ACL Policy

1. Go to [Tailscale ACL settings](https://login.tailscale.com/admin/acls)
2. Copy the contents of `acl-policy.json` from this directory
3. Paste into the ACL editor
4. Click "Save"

### 3. Enable MagicDNS and HTTPS

1. Go to [Tailscale DNS settings](https://login.tailscale.com/admin/dns)
2. Toggle "Enable MagicDNS"
3. Toggle "Enable HTTPS"

### 4. Install Tailscale Operator with Helm

```bash
# Add Tailscale Helm repository
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update

# Create namespace
kubectl apply -f namespace.yaml

# Install operator with OAuth credentials
helm install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale \
  --set oauth.clientId=<YOUR_CLIENT_ID> \
  --set oauth.clientSecret=<YOUR_CLIENT_SECRET>

# Or use the secret method:
# 1. Create oauth-secret.yaml from oauth-secret.yaml.example
# 2. kubectl apply -f oauth-secret.yaml
# 3. helm install tailscale-operator tailscale/tailscale-operator \
#      --namespace tailscale \
#      --set oauth.clientSecret=""
```

### 5. Deploy Connector

```bash
# Deploy the connector to advertise routes
kubectl apply -f connector.yaml

# Verify connector is running
kubectl get connector -n tailscale
kubectl get pods -n tailscale
```

### 6. Configure DNS

```bash
# Deploy DNS config
kubectl apply -f dns-config.yaml

# Wait for nameserver to start
kubectl wait --for=condition=ready pod -l app=tailscale-nameserver -n tailscale --timeout=120s

# Get Tailscale DNS service IP
TS_DNS_IP=$(kubectl get svc -n tailscale tailscale-nameserver -o jsonpath='{.spec.clusterIP}')
echo "Tailscale DNS Service IP: $TS_DNS_IP"

# Patch CoreDNS to forward .ts.net queries
kubectl get configmap coredns -n kube-system -o yaml > /tmp/coredns-backup.yaml
kubectl edit configmap coredns -n kube-system

# Add this block to the Corefile (replace <TS_DNS_IP> with actual IP):
#   ts.net:53 {
#     errors
#     cache 30
#     forward . <TS_DNS_IP>
#   }

# Restart CoreDNS
kubectl rollout restart deployment/coredns -n kube-system
```

### 7. Tag GPU Machine

On your external GPU inference machine:

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate with tag
sudo tailscale up --advertise-tags=tag:gpu-inference

# Verify connectivity
tailscale status
```

### 8. Test Connectivity

```bash
# From your local machine (on tailnet)
tailscale status

# From a pod in the cluster
kubectl run test-tailscale --image=nicolaka/netshoot -it --rm --restart=Never -- /bin/bash

# Inside the pod:
ping gpu-machine.your-tailnet.ts.net
curl http://gpu-machine.your-tailnet.ts.net:8080/health
nslookup gpu-machine.your-tailnet.ts.net
```

## Verification

### Check Operator Status

```bash
kubectl get pods -n tailscale
kubectl logs -n tailscale -l app=tailscale-operator
```

### Check Connector Status

```bash
kubectl get connector -n tailscale
kubectl describe connector gpu-inference-connector -n tailscale
```

### Check DNS Resolution

```bash
# From a pod
kubectl run test --image=nicolaka/netshoot -it --rm -- nslookup gpu-machine.your-tailnet.ts.net

# Should resolve to Tailscale IP (100.x.x.x)
```

## Troubleshooting

### Operator not starting

```bash
# Check logs
kubectl logs -n tailscale -l app=tailscale-operator

# Check OAuth secret
kubectl get secret -n tailscale tailscale-operator-oauth -o yaml

# Verify OAuth credentials in Tailscale admin console
```

### Connector not appearing in Tailscale admin

```bash
# Check connector status
kubectl describe connector -n tailscale gpu-inference-connector

# Check connector logs
kubectl logs -n tailscale -l tailscale.com/connector=gpu-inference-connector
```

### DNS resolution not working

```bash
# Check nameserver pod
kubectl get pods -n tailscale -l app=tailscale-nameserver

# Check CoreDNS configuration
kubectl get configmap coredns -n kube-system -o yaml

# Test DNS from pod
kubectl run test --image=nicolaka/netshoot -it --rm -- nslookup gpu-machine.your-tailnet.ts.net
```

### Can't reach GPU machine from pods

```bash
# Verify GPU machine is online in Tailscale
tailscale status

# Check ACL policy allows traffic
# Go to: https://login.tailscale.com/admin/acls

# Check connector routes are advertised
kubectl describe connector -n tailscale gpu-inference-connector

# Approve routes in Tailscale admin console (if needed)
# Go to: https://login.tailscale.com/admin/machines
```

## Cleanup

```bash
# Uninstall operator
helm uninstall tailscale-operator -n tailscale

# Delete resources
kubectl delete -f connector.yaml
kubectl delete -f dns-config.yaml
kubectl delete namespace tailscale
```

## References

- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)
- [Tailscale Subnet Routers](https://tailscale.com/kb/1019/subnets)
- [Tailscale ACL Documentation](https://tailscale.com/kb/1018/acls)
