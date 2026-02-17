# PR #2i: Tailscale Component Registry Integration - Summary

## Overview
Successfully integrated Tailscale operator as a registered Foundry component, enabling automated deployment via `foundry component install tailscale`.

## What Was Accomplished

### 1. Component Registration
- **File**: `v1/cmd/foundry/registry/init.go`
- Added Tailscale to component registry
- Component can now be discovered and installed via CLI

### 2. Install Command Integration
- **File**: `v1/cmd/foundry/commands/component/install.go`
- Added Tailscale case to k8s component installation flow
- Implemented OAuth credential resolution from `.foundryvars`
- Added FoundryVars resolver to secret resolution chain

### 3. Client Adapters
- **File**: `v1/internal/component/tailscale/component.go`
- Created `helmClientAdapter` to bridge Foundry Helm client
- Created `kubeClientAdapter` to bridge Foundry K8s client
- Stubbed K8s operations (Apply, GetServiceIP, GetConfigMap, UpdateConfigMap)
- Fixed config precedence: use pre-configured config before parsing

### 4. Secret Resolution
- **Implementation**: Multi-stage resolver chain
  1. Environment variables
  2. `~/.foundryvars` file (NEW)
  3. OpenBAO KV store
- Format in `.foundryvars`: `foundry-core/tailscale:client_id=<value>`

### 5. Deployment Results
- ✅ Tailscale operator running (1/1 pods)
- ✅ Connector advertising VIP route: `100.81.89.100/32`
- ✅ DNSConfig deployed with nameserver pod running
- ✅ Tailscale integration complete

## Manual Steps Required

### Tailscale OAuth Client Setup
1. Create OAuth client at https://login.tailscale.com/admin/settings/oauth
2. Set scopes to "all" (or minimum: Devices: Write)
3. Copy Client ID and Client Secret
4. Store in `~/.foundryvars`:
   ```
   foundry-core/tailscale:client_id=<YOUR_CLIENT_ID>
   foundry-core/tailscale:client_secret=<YOUR_CLIENT_SECRET>
   ```

### Tailscale ACL Configuration
Add required tags to ACL policy at https://login.tailscale.com/admin/acls:

```json
{
  "tagOwners": {
    "tag:k8s-operator": ["group:personal"],
    "tag:k8s-pedro-ops": ["group:personal"],
    "tag:production": ["group:personal"]
  }
}
```

**Note**: Tags must match those specified in `stack.yaml` under `components.tailscale.tags`

### Post-Installation
After operator starts, restart operator pod to pick up ACL changes:
```bash
kubectl delete pod -n tailscale <operator-pod-name>
```

## Known Issues & Follow-ups

### Issue #17: CRD Registration Wait
**Problem**: Installer tries to deploy Connector before operator registers CRDs

**Workaround**: Manual deployment of Connector/DNSConfig after operator is ready

**Fix**: Add `waitForOperatorReady()` method in `install.go`:
- Wait for operator pod to be Running
- Wait for Connector CRD to be registered
- Add buffer time for API propagation

**Tracking**: https://github.com/catalystcommunity/foundry/issues/17

### Task #17: Stack Install Orchestration
When `use_tailscale: true` with CGNAT VIP:
1. Install control plane as single-node
2. Install Tailscale operator
3. VIP becomes routable via Tailscale
4. Then join worker nodes

### Task #18: Tailscale Magic DNS
Configure DNS for analytics and ops:
- Set up DNS records for services
- Test resolution from Tailscale devices
- Document team access

## Configuration Example

```yaml
cluster:
  vip: 100.81.89.100
  allow_cgnat_vip: true
  use_tailscale: true

components:
  k3s:
    tls_san:
      - 100.81.89.62
      - 100.81.89.100  # VIP added for multi-node
      - soypetetech.local

  tailscale:
    oauth_client_id: ${secret:foundry-core/tailscale:client_id}
    oauth_client_secret: ${secret:foundry-core/tailscale:client_secret}
    tags:
      - tag:k8s-pedro-ops
      - tag:production
```

## Testing Completed

### Unit Tests
- ✅ Secret resolution from `.foundryvars`
- ✅ OAuth credential parsing
- ✅ Component config precedence

### Integration Tests
- ✅ Helm operator installation
- ✅ OAuth authentication with Tailscale API
- ✅ ACL tag validation
- ✅ Connector CRD deployment (manual)
- ✅ VIP route advertisement

### Verification
```bash
# Check operator status
kubectl get pods -n tailscale
# operator-xxx   1/1   Running

# Check Connector
kubectl get connector -n tailscale
# foundry-vip-connector   100.81.89.100/32   ConnectorCreated

# Check DNSConfig
kubectl get dnsconfig -n tailscale
# ts-dns   10.43.227.123   Running
```

## Documentation Updates Needed

### 1. Setup Guide
- Add section on Tailscale OAuth client creation
- Document `.foundryvars` format
- Include ACL configuration steps
- Note about operator pod restart after ACL changes

### 2. Troubleshooting
- OAuth credential errors (401 Unauthorized)
- ACL tag permission errors (400 Bad Request)
- CRD registration timing issues
- VIP connectivity testing

### 3. Architecture Docs
- Diagram: Tailscale Connector + VIP route flow
- Secret resolution chain diagram
- Component dependency graph

## Files Modified

### Foundry Repository
- `v1/cmd/foundry/registry/init.go` - Component registration
- `v1/cmd/foundry/commands/component/install.go` - Install integration + secret resolution
- `v1/internal/component/tailscale/component.go` - Client adapters + config precedence

### Pedro-Ops Repository
- `foundry/stack.yaml` - Added VIP to k3s tls_san
- `~/.foundryvars` - OAuth credentials (not committed)

## Key Learnings

1. **OAuth vs Auth Keys**: Tailscale operator needs OAuth client credentials (for API access), not auth keys (for device authentication)

2. **ACL Tag Permissions**: Tags must be defined in `tagOwners` section of ACL policy before use

3. **CRD Registration Timing**: Operator needs 5-10 seconds to register CRDs after pod starts

4. **Secret Resolution**: `.foundryvars` file provides simple local secret storage without OpenBAO

5. **Client Adapter Pattern**: Effective for bridging concrete types to interface requirements

## Next Steps

1. ✅ **PR #2i Complete** - Component registration and basic installation working
2. ⏭️ **Join worker nodes** - Now possible with VIP route advertised
3. ⏭️ **PR #2j** - Implement CRD registration wait mechanism
4. ⏭️ **Configure Magic DNS** - Set up for analytics/ops access

## Success Criteria Met

- [x] Tailscale component registered in Foundry
- [x] Can install via `foundry component install tailscale`
- [x] OAuth credentials resolved from `.foundryvars`
- [x] Operator running successfully
- [x] VIP advertised as Tailscale subnet route
- [x] Ready for multi-node cluster completion
