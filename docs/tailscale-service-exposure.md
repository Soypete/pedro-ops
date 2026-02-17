# Tailscale Service Exposure Guide

## Overview

This guide explains how to expose Kubernetes services via Tailscale in the pedro-ops cluster.

## The Port Forwarding Issue (What We Learned)

### Problem
When we first tried to expose Metabase via Tailscale using a **LoadBalancer service**, we encountered `ERR_CONNECTION_REFUSED` errors.

### Root Cause
Tailscale's Kubernetes operator supports two different modes for exposing services:

1. **LoadBalancer Services** - Good for **raw TCP services** (like databases, SSH, Kubernetes API)
   - Creates a Tailscale proxy that forwards TCP traffic
   - Works great for services like PostgreSQL (port 5432) or K8s API (port 6443)
   - Does NOT automatically configure HTTP/HTTPS routing

2. **Ingress Resources** - Required for **HTTP/HTTPS services** (like web apps, APIs)
   - Creates a Tailscale proxy with proper HTTP/HTTPS handling
   - Automatically manages TLS certificates
   - Properly routes HTTP traffic based on hostnames and paths

### What Went Wrong
We created a LoadBalancer service for Contour (HTTP ingress controller):
```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: analytics
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  ports:
    - port: 80
      targetPort: 8080
    - port: 443
      targetPort: 8443
```

The Tailscale operator created a proxy pod, but it didn't configure HTTP routing. The pod wasn't listening on ports 80/443, so connections were refused.

### The Fix
Use a **Tailscale Ingress** instead:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    tailscale.com/tailnet-fqdn: analytics.tail6fbc5.ts.net
    tailscale.com/tags: tag:k8s-pedro-ops,tag:production
spec:
  ingressClassName: tailscale
  defaultBackend:
    service:
      name: metabase
      port:
        number: 3000
```

This creates a proper HTTP/HTTPS proxy that handles web traffic correctly.

## How to Expose Services via Tailscale

### Method 1: LoadBalancer Service (for TCP services)

**Use for:** Databases, SSH, APIs that use raw TCP

**Example: PostgreSQL**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-tailscale
  namespace: default
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: postgres
    tailscale.com/tags: tag:k8s-pedro-ops,tag:production
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app: postgresql
  ports:
    - name: postgresql
      port: 5432
      targetPort: 5432
```

**Result:** Accessible at `postgres.tail6fbc5.ts.net:5432`

### Method 2: Ingress Resource (for HTTP/HTTPS services)

**Use for:** Web applications, REST APIs, anything HTTP-based

**Example: Metabase**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: analytics-tailscale
  namespace: eleduck-analytics
  annotations:
    tailscale.com/tailnet-fqdn: analytics.tail6fbc5.ts.net
    tailscale.com/tags: tag:k8s-pedro-ops,tag:production
spec:
  ingressClassName: tailscale
  defaultBackend:
    service:
      name: metabase
      port:
        number: 3000
  tls:
    - hosts:
        - analytics
```

**Result:** Accessible at `https://analytics-1.tail6fbc5.ts.net`

## Tailscale Magic DNS Configuration

Magic DNS allows you to use custom domain names instead of `.tail6fbc5.ts.net` hostnames.

### Setup Steps

1. **Go to Tailscale Admin Console**
   - Navigate to https://login.tailscale.com/admin/dns

2. **Add a Nameserver (Optional)**
   - For `soypetetech.local` domain
   - Add your PowerDNS server as a custom nameserver
   - This allows Tailscale devices to resolve internal cluster DNS

3. **Add Search Domains**
   - Add `soypetetech.local` to search domains
   - This lets you use short names like `analytics` instead of full FQDNs

4. **Create DNS Records**
   - Option A: Use Tailscale's MagicDNS CNAME records
     ```
     analytics.soypetetech.local -> analytics-1.tail6fbc5.ts.net
     ```

   - Option B: Use Tailscale's DNS override
     ```
     analytics.soypetetech.local -> 100.69.229.114
     ```

### Current Working URLs

| Service | Tailscale URL | Custom Domain (after Magic DNS) |
|---------|---------------|--------------------------------|
| Metabase | `https://analytics-1.tail6fbc5.ts.net` | `https://analytics.soypetetech.local` |
| K8s API | `https://pedro-ops-api.tail6fbc5.ts.net:6443` | `https://pedro-ops.soypetetech.local:6443` |

## Using the helm/tailscale-ingresses Chart

For managing LoadBalancer services (TCP services like databases):

### 1. Add a New Service
Edit `helm/tailscale-ingresses/values.yaml`:

```yaml
services:
  - name: analytics
    enabled: true
    hostname: analytics
    namespace: projectcontour
    selector:
      app.kubernetes.io/name: contour
      app.kubernetes.io/component: envoy
    ports:
      - name: http
        port: 80
        targetPort: http
      - name: https
        port: 443
        targetPort: https

  # Add PostgreSQL
  - name: postgres
    enabled: true
    hostname: postgres
    namespace: default
    selector:
      app: postgresql
    ports:
      - name: postgresql
        port: 5432
        targetPort: 5432
```

### 2. Deploy
```bash
helm upgrade tailscale-ingresses ./helm/tailscale-ingresses
```

### 3. Verify
```bash
kubectl get svc -A | grep tailscale
kubectl get pods -n tailscale
```

## For HTTP Services: Use Kubernetes Ingress

Create an Ingress resource in `k8s/tailscale/`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-tailscale
  namespace: myapp
  annotations:
    tailscale.com/tailnet-fqdn: myapp.tail6fbc5.ts.net
    tailscale.com/tags: tag:k8s-pedro-ops,tag:production
spec:
  ingressClassName: tailscale
  rules:
    - host: myapp
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-service
                port:
                  number: 8080
```

Apply:
```bash
kubectl apply -f k8s/tailscale/myapp-ingress.yaml
```

## Troubleshooting

### Connection Refused
- **For TCP services:** Check if using LoadBalancer service type
- **For HTTP services:** Check if using Ingress resource with `ingressClassName: tailscale`

### DNS Not Resolving
1. Verify Tailscale device is connected: `tailscale status`
2. Check Magic DNS is enabled in Tailscale admin console
3. Verify search domains are configured

### TLS Certificate Errors
- Tailscale Ingress automatically provisions TLS certificates
- Wait 1-2 minutes for cert provisioning
- Check ingress status: `kubectl describe ingress <name> -n <namespace>`

## Best Practices

1. **Use Ingress for HTTP/HTTPS** - Don't use LoadBalancer for web apps
2. **Tag everything** - Always use `tag:k8s-pedro-ops,tag:production` for ACL policies
3. **Use descriptive hostnames** - `analytics`, `postgres`, `grafana` not `service1`, `app2`
4. **Document exposed services** - Keep this guide updated when adding new services
5. **No Funnel** - Only expose to your tailnet, not publicly via Funnel

## Security Notes

- All exposed services are only accessible via your Tailscale network
- Tailscale ACL policies control which devices can access which services
- No ports are exposed to the public internet
- TLS is automatically configured for Ingress resources
- Use tags for group-based access control

## Quick Reference

```bash
# List all Tailscale-exposed services
kubectl get svc -A | grep tailscale
kubectl get ingress -A | grep tailscale

# Check Tailscale operator logs
kubectl logs -n tailscale operator-<pod-name>

# Check Tailscale proxy pod logs
kubectl logs -n tailscale ts-<service-name>-<hash>-0

# Verify Tailscale connection from proxy pod
kubectl exec -n tailscale ts-<service-name>-<hash>-0 -- tailscale status
kubectl exec -n tailscale ts-<service-name>-<hash>-0 -- tailscale serve status
```
