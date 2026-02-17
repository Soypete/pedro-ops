#!/bin/bash
set -euo pipefail

echo "🔐 Setting up Tailscale secrets for pedro-ops..."
echo ""

# Check 1Password CLI
if ! command -v op &> /dev/null; then
    echo "❌ 1Password CLI not found. Install with: brew install --cask 1password-cli"
    exit 1
fi

# Check if signed in
if ! op vault list &> /dev/null; then
    echo "📝 Signing in to 1Password..."
    eval $(op signin)
fi

echo "🔍 Retrieving secrets from 1Password..."

# Retrieve secrets from 1Password
TS_CLIENT_ID=$(op read "op://pedro/TS_CLIENT_ID/credential")
TS_CLIENT_SECRET=$(op read "op://pedro/TS_CLIENT_SECRET/credential")

if [ -z "$TS_CLIENT_ID" ] || [ -z "$TS_CLIENT_SECRET" ]; then
    echo "❌ Failed to retrieve secrets from 1Password"
    exit 1
fi

echo "✅ Secrets retrieved from 1Password"

# Create or update ~/.foundryvars
FOUNDRYVARS="$HOME/.foundryvars"

echo ""
echo "📝 Updating $FOUNDRYVARS..."

# Check if file exists and backup
if [ -f "$FOUNDRYVARS" ]; then
    cp "$FOUNDRYVARS" "$FOUNDRYVARS.backup"
    echo "📦 Backed up existing file to $FOUNDRYVARS.backup"

    # Remove existing Tailscale entries
    grep -v "^foundry-core/tailscale:" "$FOUNDRYVARS" > "$FOUNDRYVARS.tmp" || true
    mv "$FOUNDRYVARS.tmp" "$FOUNDRYVARS"
fi

# Append Tailscale secrets to ~/.foundryvars
# Format: foundry-core/tailscale:client_id=value
echo "" >> "$FOUNDRYVARS"
echo "# Tailscale OAuth credentials (added $(date))" >> "$FOUNDRYVARS"
echo "foundry-core/tailscale:client_id=$TS_CLIENT_ID" >> "$FOUNDRYVARS"
echo "foundry-core/tailscale:client_secret=$TS_CLIENT_SECRET" >> "$FOUNDRYVARS"

# Set restrictive permissions
chmod 600 "$FOUNDRYVARS"

echo "✅ Secrets stored in $FOUNDRYVARS"
echo ""
echo "Next steps:"
echo "  1. Deploy: foundry stack install --config foundry/stack.yaml"
echo "  2. Check: kubectl get pods -n tailscale"
echo "  3. Verify: kubectl get connector -n tailscale"
echo ""
echo "Note: Secrets are stored in ~/.foundryvars (local development)"
echo "      For production, these will use OpenBAO once implemented"
echo ""
