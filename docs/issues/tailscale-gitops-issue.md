# GitOps: Automate Tailscale ACL Management

## Overview
Implement GitOps workflow to manage Tailscale ACL configuration through Git and CI/CD, enabling version control, peer review, and automated updates for network policies.

## Motivation
- Current manual ACL management through Tailscale admin console lacks version control
- No audit trail or PR-based review for network policy changes
- Difficult to keep ACL in sync with infrastructure changes
- Preparing for multi-control-plane HA cluster with Tailscale integration

## Goals
1. Store Tailscale ACL policy in Git (`tailscale/acl.json` or `tailscale/policy.hujson`)
2. Automate ACL updates via GitHub Actions on merge to main
3. Add validation and pre-commit hooks for ACL syntax
4. Enable PR-based review process for network policy changes

## Implementation Plan

### Phase 1: Setup
- [ ] Create `tailscale/` directory in repo
- [ ] Export current ACL policy from Tailscale admin console
- [ ] Store in Git with initial documentation

### Phase 2: Automation
- [ ] Set up Tailscale OAuth client for API access
- [ ] Create GitHub Actions workflow using `tailscale/gitops-acl-action`
- [ ] Configure secrets (TAILSCALE_OAUTH_CLIENT_ID, TAILSCALE_OAUTH_SECRET)
- [ ] Test in non-production environment

### Phase 3: Validation
- [ ] Add pre-commit hooks for ACL syntax validation
- [ ] Add CI checks for policy correctness
- [ ] Enable dry-run mode for preview before apply

### Phase 4: Documentation
- [ ] Document ACL update process in README
- [ ] Add troubleshooting guide
- [ ] Create examples for common ACL patterns

## Example GitHub Actions Workflow

```yaml
name: Update Tailscale ACL
on:
  push:
    branches: [main]
    paths:
      - 'tailscale/policy.hujson'

jobs:
  acl-update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: tailscale/gitops-acl-action@v1
        with:
          api-key: ${{ secrets.TAILSCALE_API_KEY }}
          tailnet: ${{ secrets.TAILSCALE_TAILNET }}
          policy-file: tailscale/policy.hujson
```

## Benefits
- **Version Control**: All ACL changes tracked in Git
- **Peer Review**: Changes reviewed via PRs before applying
- **Automation**: Reduce manual errors and toil
- **Disaster Recovery**: ACL configuration backed up in Git
- **Compliance**: Clear audit trail of network policy changes

## References
- [Tailscale GitOps ACL Action](https://github.com/tailscale/gitops-acl-action)
- [Tailscale ACL Documentation](https://tailscale.com/kb/1018/acls/)
- [HuJSON Format Guide](https://github.com/tailscale/hujson)

## Related Work
- Foundry PR #1: CGNAT IP support for VIP
- Foundry PR #2 (planned): Full Tailscale integration with operator
- Pedro-ops: Multi-control-plane HA cluster setup
