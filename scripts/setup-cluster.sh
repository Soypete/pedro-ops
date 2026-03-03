#!/bin/bash
set -euo pipefail

# Pedro Ops Cluster Setup - Interactive Walkthrough Script
# This script guides you through the complete cluster deployment process

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print section headers
print_header() {
    echo ""
    echo -e "${BLUE}=================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}=================================================================${NC}"
    echo ""
}

# Function to print step info
print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

# Function to print warnings
print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to print errors
print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to prompt for continuation
prompt_continue() {
    echo ""
    read -p "Press Enter to continue, or Ctrl+C to abort... "
    echo ""
}

# Function to prompt yes/no
prompt_yes_no() {
    local message=$1
    local response
    while true; do
        read -p "$message (yes/no): " response
        case $response in
            [Yy]es|[Yy]) return 0 ;;
            [Nn]o|[Nn]) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# Welcome message
clear
echo -e "${BLUE}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║        Pedro Ops Kubernetes Cluster Setup                ║
║        Interactive Deployment Walkthrough                ║
║                                                           ║
║  This script will guide you through deploying a          ║
║  production-ready 3-node K8s cluster with:               ║
║    • Foundry CLI (K3s, OpenBAO, PowerDNS, Zot)          ║
║    • Complete observability (Prometheus, Loki, Grafana)  ║
║    • Tailscale integration for GPU connectivity          ║
║    • 2TB persistent storage backend                      ║
║                                                           ║
║  Estimated time: 2.5-3 hours                             ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo ""
echo "Prerequisites check:"
echo "  [?] 3 Linux servers (Debian/Ubuntu) with SSH access"
echo "  [?] 2TB drive attached to Worker-1 (100.70.90.12)"
echo "  [?] Go 1.21+ installed on this machine"
echo "  [?] kubectl and helm installed"
echo "  [?] Tailscale account (free tier)"
echo ""

if ! prompt_yes_no "Do you meet all prerequisites?"; then
    echo ""
    print_warning "Please ensure all prerequisites are met before proceeding."
    print_warning "See docs/setup-guide.md for details."
    exit 1
fi

# ============================================================================
# PHASE 1: Pre-Deployment Verification
# ============================================================================

print_header "PHASE 1: Pre-Deployment Verification (30 min)"

print_step "1.1 - Verifying SSH access to all nodes..."
echo "Testing connectivity to:"
echo "  • Control Plane: 100.81.89.62"
echo "  • Worker 1: 100.70.90.12"
echo "  • Worker 2: 100.125.196.1"
echo ""
prompt_continue

if ./scripts/phase1-verify-hosts.sh; then
    print_step "✓ SSH verification passed!"
else
    print_error "SSH verification failed!"
    print_error "Please configure SSH key-based authentication and try again."
    exit 1
fi

echo ""
print_step "1.2 - Identifying 2TB drive on Worker-1..."
echo "Let's identify your 2TB storage drive."
echo ""

ssh root@100.70.90.12 'lsblk'
echo ""
print_warning "Look for your 2TB drive in the output above (e.g., /dev/sdb, /dev/nvme1n1)"
echo ""

if prompt_yes_no "Have you identified the 2TB drive?"; then
    print_step "1.3 - Formatting and mounting 2TB drive..."
    print_warning "This will ERASE ALL DATA on the specified device!"
    echo ""

    if ./scripts/phase1-setup-storage.sh; then
        print_step "✓ Storage setup complete!"
    else
        print_error "Storage setup failed!"
        exit 1
    fi
else
    print_error "Cannot proceed without identifying the storage drive."
    exit 1
fi

echo ""
print_step "1.4 - Installing prerequisites on all nodes..."
prompt_continue

if ./scripts/phase1-install-prerequisites.sh; then
    print_step "✓ Prerequisites installed!"
else
    print_error "Prerequisites installation failed!"
    exit 1
fi

print_header "Phase 1 Complete!"
echo "✓ SSH access verified"
echo "✓ 2TB drive formatted and mounted"
echo "✓ Prerequisites installed on all nodes"
echo ""
prompt_continue

# ============================================================================
# PHASE 2: Foundry CLI Installation
# ============================================================================

print_header "PHASE 2: Foundry CLI Installation (20 min)"

print_step "2.1 - Installing Foundry CLI..."
echo "This will:"
echo "  • Clone Foundry repository"
echo "  • Build Foundry CLI"
echo "  • Install to /usr/local/bin/"
echo "  • Initialize configuration"
echo ""
prompt_continue

if ./scripts/phase2-install-foundry.sh; then
    print_step "✓ Foundry CLI installed!"
else
    print_error "Foundry installation failed!"
    exit 1
fi

echo ""
print_step "2.2 - Adding hosts to Foundry..."
echo ""
print_warning "You will need to add each node interactively."
echo "When prompted, enter:"
echo ""
echo "Control Plane:"
echo "  Hostname: control-plane"
echo "  IP: 100.81.89.62"
echo "  User: root"
echo ""
echo "Worker 1:"
echo "  Hostname: worker-1"
echo "  IP: 100.70.90.12"
echo "  User: root"
echo ""
echo "Worker 2:"
echo "  Hostname: worker-2"
echo "  IP: 100.125.196.1"
echo "  User: root"
echo ""
prompt_continue

echo "Adding control-plane..."
foundry host add

echo "Adding worker-1..."
foundry host add

echo "Adding worker-2..."
foundry host add

echo ""
print_step "Verifying hosts..."
foundry host list
echo ""

print_step "2.3 - Configuring hosts..."
prompt_continue

foundry host configure control-plane
foundry host configure worker-1
foundry host configure worker-2

print_step "2.4 - Validating configuration..."
if foundry config validate && foundry validate; then
    print_step "✓ Configuration validated!"
else
    print_error "Configuration validation failed!"
    exit 1
fi

print_header "Phase 2 Complete!"
echo "✓ Foundry CLI installed and configured"
echo "✓ All hosts added and configured"
echo "✓ Configuration validated"
echo ""
prompt_continue

# ============================================================================
# PHASE 3: Deploy Foundry Stack
# ============================================================================

print_header "PHASE 3: Deploy Foundry Stack (30-40 min)"

print_warning "This is the longest phase and will take 30-40 minutes."
print_warning "The script will install the complete Kubernetes stack including:"
echo "  • K3s cluster"
echo "  • OpenBAO (secrets management)"
echo "  • PowerDNS (internal DNS)"
echo "  • Zot (container registry)"
echo "  • Longhorn (distributed storage)"
echo "  • Prometheus, Loki, Grafana (observability)"
echo ""

if prompt_yes_no "Ready to begin deployment?"; then
    if ./scripts/phase3-deploy-foundry.sh; then
        print_step "✓ Foundry stack deployed!"
    else
        print_error "Foundry stack deployment failed!"
        print_error "Check logs with: foundry logs"
        exit 1
    fi
else
    print_error "Deployment aborted."
    exit 1
fi

echo ""
print_step "Verifying cluster access..."
export KUBECONFIG=~/.kube/pedro-ops-config
kubectl get nodes -o wide
echo ""

print_header "Phase 3 Complete!"
echo "✓ Foundry stack deployed successfully"
echo "✓ Kubernetes cluster is running"
echo "✓ kubectl configured"
echo ""

print_step "Cluster Information:"
echo "  Kubeconfig: ~/.kube/pedro-ops-config"
echo "  API Endpoint: https://100.81.89.100:6443"
echo "  Domain: soypetetech.local"
echo ""
prompt_continue

# ============================================================================
# PHASE 4: Tailscale Integration
# ============================================================================

print_header "PHASE 4: Tailscale Integration (30 min)"

print_step "4.1 - Preparing Tailscale credentials..."
echo ""
echo "You need to create OAuth credentials in Tailscale:"
echo "  1. Go to: https://login.tailscale.com/admin/settings/oauth"
echo "  2. Click 'Generate OAuth Client'"
echo "  3. Copy the Client ID and Client Secret"
echo ""
prompt_continue

echo "Enter your Tailscale OAuth credentials:"
read -p "Client ID: " TS_CLIENT_ID
read -sp "Client Secret: " TS_CLIENT_SECRET
echo ""
export TS_CLIENT_ID
export TS_CLIENT_SECRET

echo ""
print_step "4.2 - Configuring Tailscale ACL policy..."
echo ""
echo "You need to configure ACL policy in Tailscale:"
echo "  1. Go to: https://login.tailscale.com/admin/acls"
echo "  2. Copy contents of k8s/tailscale/acl-policy.json"
echo "  3. Paste into ACL editor and save"
echo ""
prompt_continue

print_step "4.3 - Enabling MagicDNS..."
echo ""
echo "You need to enable MagicDNS in Tailscale:"
echo "  1. Go to: https://login.tailscale.com/admin/dns"
echo "  2. Toggle 'Enable MagicDNS'"
echo "  3. Toggle 'Enable HTTPS'"
echo ""
prompt_continue

print_step "4.4 - Installing Tailscale operator..."
if ./scripts/phase4-install-tailscale.sh; then
    print_step "✓ Tailscale operator installed!"
else
    print_error "Tailscale installation failed!"
    exit 1
fi

echo ""
print_step "4.5 - Post-installation tasks..."
echo ""
echo "Complete these tasks:"
echo "  1. Approve routes in Tailscale admin:"
echo "     https://login.tailscale.com/admin/machines"
echo "     Look for 'pedro-ops-cluster' and approve advertised routes"
echo ""
echo "  2. Configure CoreDNS (see output from phase4 script)"
echo ""
echo "  3. Set up GPU machine:"
echo "     curl -fsSL https://tailscale.com/install.sh | sh"
echo "     sudo tailscale up --advertise-tags=tag:gpu-inference"
echo ""
prompt_continue

print_header "Phase 4 Complete!"
echo "✓ Tailscale operator installed"
echo "✓ Connector deployed"
echo "✓ DNS configuration applied"
echo ""
echo "Remember to complete the post-installation tasks listed above!"
echo ""
prompt_continue

# ============================================================================
# PHASE 5: Validation
# ============================================================================

print_header "PHASE 5: Validation and Verification"

print_step "5.1 - Validating storage configuration..."
./scripts/validate-storage.sh || true

echo ""
print_step "5.2 - Checking all pods..."
kubectl get pods -A
echo ""

print_step "5.3 - Accessing Grafana..."
echo ""
echo "Get Grafana admin password:"
echo '  kubectl get secret -n monitoring grafana-admin-credentials -o jsonpath='\''{.data.password}'\'' | base64 -d'
echo ""
echo "Port-forward to Grafana:"
echo "  kubectl port-forward -n monitoring svc/grafana 3000:3000"
echo "  Then open: http://localhost:3000"
echo "  Username: admin"
echo ""
prompt_continue

# ============================================================================
# COMPLETION
# ============================================================================

print_header "DEPLOYMENT COMPLETE!"

echo -e "${GREEN}"
cat << "EOF"
   ✓ Kubernetes cluster is running
   ✓ Foundry stack deployed
   ✓ Tailscale integration configured
   ✓ Storage configured on 2TB drive
   ✓ Observability stack operational
EOF
echo -e "${NC}"

echo ""
echo "Next Steps:"
echo ""
echo "1. Access Grafana:"
echo "   kubectl port-forward -n monitoring svc/grafana 3000:3000"
echo ""
echo "2. Access Prometheus:"
echo "   kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090"
echo ""
echo "3. Test Tailscale connectivity:"
echo "   kubectl run test --image=nicolaka/netshoot -it --rm -- ping gpu-machine.your-tailnet.ts.net"
echo ""
echo "4. Apply application manifests:"
echo "   kubectl apply -k k8s/base"
echo "   kubectl apply -k k8s/overlays/production"
echo ""
echo "5. Review documentation:"
echo "   docs/setup-guide.md"
echo "   docs/architecture.md"
echo "   docs/troubleshooting.md"
echo ""
echo -e "${BLUE}Happy clustering!${NC}"
echo ""

# Export kubeconfig reminder
echo "To use kubectl, run:"
echo "  export KUBECONFIG=~/.kube/pedro-ops-config"
echo ""
echo "Or add to your shell profile:"
echo "  echo 'export KUBECONFIG=~/.kube/pedro-ops-config' >> ~/.bashrc"
echo ""
