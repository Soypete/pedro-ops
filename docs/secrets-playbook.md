# Secrets Management Playbook

This playbook covers how to manage secrets using OpenBAO and the Agent Injector.

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ 1Password   │────▶│ OpenBAO     │────▶│ K8s Pods    │
│ (source of  │     │ (secrets    │     │ (agent      │
│  truth)     │     │  store)     │     │  injector)  │
└─────────────┘     └─────────────┘     └─────────────┘
```

## Prerequisites

- OpenBAO server running at `100.81.89.62:8200`
- OpenBAO Agent Injector deployed in cluster (`openbao-injector-agent-injector-*`)
- `vault` CLI installed (`brew install hashicorp/tap/vault`)
- `op` CLI installed (`brew install 1password-cli`)
- `yq` installed (`brew install yq`)

## Quick Reference

```bash
# Set environment
export VAULT_ADDR=http://100.81.89.62:8200
export VAULT_TOKEN=<token-from-1password>

# List secrets
vault kv list secret/

# Get a secret
vault kv get secret/pedro/discord

# Put a secret
vault kv put secret/pedro/discord DISCORD_SECRET="value"
```

## Sync Secrets from 1Password to OpenBAO

### Step 1: Create secrets mapping config

Create `secrets/secrets-map.yaml`:

```yaml
secrets:
  - openbao_path: secret/pedro/discord
    description: Discord bot credentials
    keys:
      - key: DISCORD_SECRET
        onepassword_ref: op://pedro/DISCORD_SECRET/credential
      - key: DISCORD_CLIENT_ID
        onepassword_ref: op://pedro/DISCORD_CLIENT_ID/credential

  - openbao_path: secret/pedro/supabase
    description: Supabase credentials
    keys:
      - key: SUPABASE_PUB_KEY
        onepassword_ref: op://pedro/SUPABASE_PUB_KEY/credential
      - key: SUPABASE_PRIV_KEY
        onepassword_ref: op://pedro/SUPABASE_PRIV_KEY/credential
      - key: SUPABASE_URL
        onepassword_ref: op://pedro/SUPABASE_URL/credential
      - key: SUPABASE_JWT
        onepassword_ref: op://pedro/SUPABASE_JWT/credential
```

### Step 2: Get OpenBAO root token

The root token is stored in 1Password under "pedro" vault, item "openbao-root-token".

### Step 3: Run sync

```bash
cd /Users/soypete/code/pedro/pedro-ops
export VAULT_ADDR=http://100.81.89.62:8200
export VAULT_TOKEN=<token>
./scripts/sync-secrets-to-openbao.sh secrets/secrets-map.yaml
```

## Deploy Apps with OpenBAO Injection

### Option 1: Use existing helm charts with annotations

Add these annotations to your deployment templates:

```yaml
metadata:
  annotations:
    # Enable agent injection
    vault.hashicorp.com/agent-inject: "true"
    # Specify the secret path
    vault.hashicorp.com/agent-inject-secret-pedro-discord: "secret/pedro/discord"
    # Template for environment variables
    vault.hashicorp.com/agent-inject-template-pedro-discord: |
      {{- with secret "secret/pedro/discord" -}}
      DISCORD_SECRET="{{ .Data.data.DISCORD_SECRET }}"
      DISCORD_CLIENT_ID="{{ .Data.data.DISCORD_CLIENT_ID }}"
      {{- end }}
```

### Option 2: Use Vault Agent Init Container

For more control, use init container to fetch secrets:

```yaml
initContainers:
  - name: vault-agent-init
    image: hashicorp/vault:1.16
    env:
      - name: VAULT_ADDR
        value: "http://100.81.89.62:8200"
    command:
      - /bin/sh
      - -c
      - |
        vault write -f auth/kubernetes/role/pedro bots ttl=1h
        vault agent -config=/etc/vault/config.hcl
    volumeMounts:
      - name: vault-config
        mountPath: /etc/vault
```

## Configure Kubernetes Auth for OpenBAO

### Step 1: Enable Kubernetes auth in OpenBAO

```bash
vault auth enable kubernetes
```

### Step 2: Configure Kubernetes auth

```bash
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR" \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

### Step 3: Create a policy for bot secrets

```bash
vault policy write pedro-bots -path "secret/pedro/*" -capabilities read
```

### Step 4: Create Kubernetes auth role

```bash
vault write auth/kubernetes/role/pedro \
  bound_service_account_names=default \
  bound_service_account_namespaces=chatbot \
  policies=pedro-bots \
  ttl=1h
```

## Troubleshooting

### Check OpenBAO status

```bash
curl -s http://100.81.89.62:8200/v1/sys/health | jq .
```

### Check Agent Injector logs

```bash
kubectl logs -n openbao -l app.kubernetes.io/name=openbao-injector-agent-injector
```

### Verify secrets exist in OpenBAO

```bash
export VAULT_ADDR=http://100.81.89.62:8200
vault kv list secret/
vault kv get secret/pedro/discord
```

### Test injection in a pod

```bash
# Deploy a test pod
kubectl run test-vault --image=busybox --restart=Never -- sleep 3600

# Exec into pod and check for injected secrets
kubectl exec test-vault -- cat /vault/secrets/pedro-discord
```

### Common errors

| Error | Solution |
|-------|----------|
| `permission denied` | Check VAULT_TOKEN is valid |
| `invalid secret path` | Ensure path exists in OpenBAO |
| `not found` in agent logs | Check Kubernetes auth role exists |
| `ImagePullBackOff` | See zot-registry-guide.md |

## Legacy: Using 1Password CLI directly

The old approach used 1Password CLI inside containers. This is deprecated but documented here for reference.

### Old flow (deprecated)

1. Create ConfigMap with `op://` references
2. Use `op run --env-file=` in container command
3. Requires OP_SERVICE_ACCOUNT_TOKEN in pod

This approach is **not recommended** because:
- Slower startup (1Password lookup each time)
- Requires 1Password connectivity from pods
- No centralized audit trail

## Kei Project Secrets

### GitHub OAuth Credentials

The Kei project uses GitHub OAuth for authentication. Credentials are stored in OpenBAO and injected via the OpenBAO Agent Injector.

#### 1. Get credentials from 1Password

```bash
# Get GitHub Client ID
op item get "kei_github_clientID" --vault pedro --reveal

# Get GitHub OAuth Secret
op item get "kai_github_oauth_secret" --vault pedro --reveal
```

#### 2. Store in OpenBAO

```bash
# Using kubectl with a temporary pod to access OpenBAO
kubectl run --rm -it tmp-shell --image=busybox --restart=Never -- sh -c "
wget -q -O - --header='X-Vault-Token: <root-token>' --header='Content-Type: application/json' \
  --post-data='{\"data\": {\"client_id\": \"<client_id>\", \"client_secret\": \"<client_secret>\"}}' \
  http://100.81.89.62:8200/v1/secret/data/kei/github
"
```

Or using Foundry's OpenBAO token (stored in `~/.foundry/openbao-keys/<cluster>/keys.json`):

```bash
# Get root token
ROOT_TOKEN=$(cat ~/.foundry/openbao-keys/test/keys.json | jq -r '.root_token')

# Store secrets
kubectl run --rm -it tmp-shell --image=busybox --restart=Never -- sh -c "
wget -q -O - --header='X-Vault-Token: $ROOT_TOKEN' --header='Content-Type: application/json' \
  --post-data='{\"data\": {\"client_id\": \"Ov23liJn1c5XbeACMmKA\", \"client_secret\": \"<secret>\"}}' \
  http://100.81.89.62:8200/v1/secret/data/kei/github
"
```

#### 3. Enable namespace for injection

By default, the OpenBAO injector ignores certain namespaces. Enable it for kei:

```bash
kubectl annotate namespace kei openbao.hashicorp.com/webhook-ignore-namespaces=false --overwrite
```

#### 4. Add annotations to deployment

In `k8s/base/oidc-bridge/deployment.yaml`:

```yaml
template:
  metadata:
    annotations:
      openbao.hashicorp.com/agent-inject: "true"
      openbao.hashicorp.com/role: "kei"
      openbao.hashicorp.com/agent-inject-secret-github: "secret/data/kei/github"
      openbao.hashicorp.com/agent-inject-template-github: |
        {{- with secret "secret/data/kei/github" -}}
        export GITHUB_CLIENT_ID="{{ .Data.data.client_id }}"
        export GITHUB_CLIENT_SECRET="{{ .Data.data.client_secret }}"
        {{- end }}
```

#### 5. Create GitHub OAuth App

Go to https://github.com/settings/developers and create a new OAuth app:

- **Application name**: kei
- **Homepage URL**: `https://kei-web-ingress.tail6fbc5.ts.net`
- **Authorization callback URL**: `https://kei-web-ingress.tail6fbc5.ts.net/auth/callback`

Use the client ID and secret from 1Password (step 1) when creating the app.

## References

- [OpenBAO Agent Injector](https://developer.hashicorp.com/vault/docs/platform/k8s/injector)
- [Kubernetes Auth Method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [1Password CLI](https://developer.1password.com/docs/cli/)