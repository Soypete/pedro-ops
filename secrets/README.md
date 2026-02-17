# Secrets Management

This directory contains tools for syncing secrets from 1Password to OpenBAO.

## Overview

Secrets are stored in 1Password and synced to OpenBAO using the `sync-secrets-to-openbao.sh` script.

**Files:**
- `secrets-map.yaml.example` - Template for secret mappings (committed)
- `secrets-map.yaml` - Your actual secret mappings (gitignored, never commit!)
- `sync-history.log` - Record of sync operations (committed, no actual secrets)

## Setup

### 1. Install Dependencies

```bash
# macOS
brew install 1password-cli hashicorp/tap/vault yq

# Linux
# Install op: https://developer.1password.com/docs/cli/get-started/
# Install vault: https://www.vaultproject.io/downloads
# Install yq: https://github.com/mikefarah/yq
```

### 2. Configure Secret Mappings

```bash
# Copy the example
cp secrets/secrets-map.yaml.example secrets/secrets-map.yaml

# Edit to match your 1Password structure
vim secrets/secrets-map.yaml
```

### 3. Set Environment Variables

```bash
# For 1Password (if not already configured)
export OP_SERVICE_ACCOUNT_TOKEN="your-token"  # For CI/CD
# OR login interactively: eval $(op signin)

# For OpenBAO
export VAULT_ADDR="http://100.81.89.62:8200"
export VAULT_TOKEN="your-root-token"
```

## Usage

### Sync Secrets Locally

```bash
# Sync all secrets defined in secrets-map.yaml
./scripts/sync-secrets-to-openbao.sh

# Use a different config file
./scripts/sync-secrets-to-openbao.sh path/to/custom-config.yaml
```

### Sync via CI/CD

Add to `.github/workflows/sync-secrets.yml`:

```yaml
name: Sync Secrets to OpenBAO

on:
  workflow_dispatch:  # Manual trigger
  schedule:
    - cron: '0 2 * * 0'  # Weekly on Sunday at 2 AM

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          brew install 1password-cli hashicorp/tap/vault yq

      - name: Sync secrets
        env:
          OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
          VAULT_ADDR: ${{ secrets.VAULT_ADDR }}
          VAULT_TOKEN: ${{ secrets.VAULT_TOKEN }}
        run: ./scripts/sync-secrets-to-openbao.sh

      - name: Commit sync log
        run: |
          git config user.name "github-actions"
          git config user.email "github-actions@github.com"
          git add secrets/sync-history.log
          git commit -m "chore: Update secret sync log" || echo "No changes"
          git push
```

## Verify Secrets in OpenBAO

```bash
# Set OpenBAO address
export VAULT_ADDR="http://100.81.89.62:8200"

# Login
vault login

# List all secrets
vault kv list secret/

# Get a specific secret
vault kv get secret/apps/twitch
vault kv get secret/eleduck-analytics/database
```

## Secret Path Convention

Use this naming convention for OpenBAO paths:

```
secret/
├── apps/              # Application credentials
│   ├── twitch
│   ├── discord
│   └── supabase
├── eleduck-analytics/ # Project-specific secrets
│   ├── database
│   ├── github
│   └── podcast-scraper
└── infrastructure/    # Infrastructure secrets
    ├── dns
    └── registry
```

## Security Notes

- ✅ `secrets-map.yaml` is in `.gitignore` - never commit it
- ✅ `sync-history.log` only contains timestamps and paths, no actual secrets
- ✅ Use 1Password Service Accounts for CI/CD
- ✅ Rotate OpenBAO root token regularly
- ⚠️ Keep `VAULT_TOKEN` secret in GitHub Actions secrets

## Troubleshooting

### "Not logged into 1Password"
```bash
eval $(op signin)
```

### "Not logged into OpenBAO/Vault"
```bash
export VAULT_ADDR="http://100.81.89.62:8200"
vault login
```

### "Config file not found"
```bash
cp secrets/secrets-map.yaml.example secrets/secrets-map.yaml
# Edit secrets-map.yaml with your mappings
```

### Verify 1Password references
```bash
# Test reading from 1Password
op read "op://pedro/TWITCH_ID/credential"
```
