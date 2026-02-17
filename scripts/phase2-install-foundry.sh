#!/bin/bash
set -euo pipefail

# Phase 2: Install and Configure Foundry CLI

echo "=== Phase 2: Foundry CLI Installation ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

FOUNDRY_REPO="https://github.com/catalystcommunity/foundry.git"
FOUNDRY_VERSION="v1"

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "Go is not installed. Please install Go 1.21 or later."
    echo "Visit: https://golang.org/doc/install"
    exit 1
fi

echo "Go version:"
go version
echo ""

# Clone Foundry repository
if [ -d "foundry-repo" ]; then
    echo "Foundry repository already cloned. Updating..."
    cd foundry-repo
    git pull
    cd ..
else
    echo "Cloning Foundry repository..."
    git clone "$FOUNDRY_REPO" foundry-repo
fi
echo ""

# Build Foundry
echo "Building Foundry CLI..."
cd foundry-repo/$FOUNDRY_VERSION
go build -o foundry ./cmd/foundry

# Install Foundry
echo "Installing Foundry to /usr/local/bin..."
sudo mv foundry /usr/local/bin/

# Verify installation
echo ""
echo "Foundry installed successfully:"
foundry --version
cd ../..

# Initialize Foundry configuration
echo ""
echo "Initializing Foundry configuration..."
foundry config init

# Copy our stack.yaml to Foundry config directory
echo "Copying stack configuration..."
mkdir -p ~/.foundry
cp foundry/stack.yaml ~/.foundry/stack.yaml

echo ""
echo -e "${GREEN}✓ Foundry CLI installed successfully!${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Add hosts to Foundry:"
echo "   foundry host add"
echo "   # For each node: control-plane (100.81.89.62), worker-1 (100.70.90.12), worker-2 (100.125.196.1)"
echo ""
echo "2. Configure hosts:"
echo "   foundry host configure control-plane"
echo "   foundry host configure worker-1"
echo "   foundry host configure worker-2"
echo ""
echo "3. Validate configuration:"
echo "   foundry config validate"
echo "   foundry validate"
echo ""
echo "4. Install the stack:"
echo "   foundry stack install"
echo ""
echo "Or run the automated setup script:"
echo "   ./scripts/phase3-deploy-foundry.sh"
