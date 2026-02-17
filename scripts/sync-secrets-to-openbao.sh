#!/bin/bash
set -euo pipefail

# Sync secrets from 1Password to OpenBAO
# Usage: ./scripts/sync-secrets-to-openbao.sh [config-file]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${1:-$PROJECT_ROOT/secrets/secrets-map.yaml}"
SYNC_LOG="$PROJECT_ROOT/secrets/sync-history.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check dependencies
check_dependencies() {
    local missing_deps=()

    if ! command -v op &> /dev/null; then
        missing_deps+=("op (1Password CLI)")
    fi

    if ! command -v vault &> /dev/null; then
        missing_deps+=("vault (OpenBAO/Vault CLI)")
    fi

    if ! command -v yq &> /dev/null; then
        missing_deps+=("yq (YAML processor)")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}Error: Missing required dependencies:${NC}"
        printf '  - %s\n' "${missing_deps[@]}"
        echo ""
        echo "Install missing dependencies with:"
        echo "  brew install hashicorp/tap/vault yq"
        echo ""
        echo "1Password CLI (op) install: brew install 1password-cli"
        exit 1
    fi

    echo -e "${GREEN}✓ All dependencies found${NC}"
}

# Check if logged into 1Password
check_op_login() {
    if ! op account get &> /dev/null; then
        echo -e "${YELLOW}Not logged into 1Password. Attempting login...${NC}"
        eval $(op signin)
    fi
}

# Check if logged into OpenBAO
check_vault_login() {
    if ! vault token lookup &> /dev/null; then
        echo -e "${RED}Error: Not logged into OpenBAO/Vault${NC}"
        echo "Set VAULT_ADDR and VAULT_TOKEN environment variables"
        echo ""
        echo "Example:"
        echo "  export VAULT_ADDR='http://100.81.89.62:8200'"
        echo "  export VAULT_TOKEN='your-root-token'"
        exit 1
    fi
}

# Parse secrets config and sync
sync_secrets() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Error: Config file not found: $config_file${NC}"
        echo "Create it from the example: cp secrets/secrets-map.yaml.example secrets/secrets-map.yaml"
        exit 1
    fi

    echo -e "${BLUE}=== Syncing Secrets from 1Password to OpenBAO ===${NC}"
    echo ""

    # Read number of secret groups
    local num_groups=$(yq '.secrets | length' "$config_file")

    for ((i=0; i<num_groups; i++)); do
        local path=$(yq ".secrets[$i].openbao_path" "$config_file")
        local description=$(yq ".secrets[$i].description // \"\"" "$config_file")
        local num_keys=$(yq ".secrets[$i].keys | length" "$config_file")

        echo -e "${GREEN}Syncing: ${YELLOW}$path${NC}"
        if [ -n "$description" ]; then
            echo -e "  Description: $description"
        fi

        # Build vault command
        local vault_cmd="vault kv put $path"
        local sync_record="$(date -u +"%Y-%m-%dT%H:%M:%SZ") | $path |"

        for ((j=0; j<num_keys; j++)); do
            local key=$(yq ".secrets[$i].keys[$j].key" "$config_file")
            local op_ref=$(yq ".secrets[$i].keys[$j].onepassword_ref" "$config_file")

            echo -n "  - Fetching $key from 1Password..."

            # Fetch from 1Password
            local value
            if value=$(op read "$op_ref" 2>/dev/null); then
                vault_cmd="$vault_cmd $key=\"$value\""
                sync_record="$sync_record $key,"
                echo -e " ${GREEN}✓${NC}"
            else
                echo -e " ${RED}✗ (not found)${NC}"
                sync_record="$sync_record $key(missing),"
            fi
        done

        # Write to OpenBAO
        echo -n "  - Writing to OpenBAO..."
        if eval "$vault_cmd" &> /dev/null; then
            echo -e " ${GREEN}✓${NC}"
            echo "$sync_record synced" >> "$SYNC_LOG"
        else
            echo -e " ${RED}✗ (failed)${NC}"
            echo "$sync_record failed" >> "$SYNC_LOG"
        fi

        echo ""
    done

    echo -e "${GREEN}=== Sync Complete ===${NC}"
    echo -e "Log: $SYNC_LOG"
}

# Main
main() {
    echo -e "${BLUE}1Password → OpenBAO Secret Sync${NC}"
    echo ""

    check_dependencies
    check_op_login
    check_vault_login

    sync_secrets "$CONFIG_FILE"
}

main "$@"
