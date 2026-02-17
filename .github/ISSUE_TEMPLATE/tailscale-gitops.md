---
name: Implement GitOps for Tailscale ACL Management
about: Automate Tailscale ACL configuration via Git and CI/CD
title: 'GitOps: Automate Tailscale ACL updates'
labels: ['enhancement', 'infrastructure', 'gitops']
assignees: ''
---

## Problem Statement

Currently, Tailscale ACL configuration is managed manually through the Tailscale admin console. This creates several issues:
- No version control for network policies
- No audit trail for ACL changes
- Manual process prone to errors
- Can't review ACL changes via pull requests
- Difficult to sync ACL state with infrastructure changes

## Proposed Solution

Implement GitOps workflow for Tailscale ACL management:

1. **Store ACL configuration in Git**
   - Define ACL policy in `tailscale/acl.json` or `tailscale/policy.hujson`
   - Version control all network policy changes
   - Enable PR-based review process

2. **Automate ACL updates via CI/CD**
   - GitHub Actions workflow to validate and apply ACL changes
   - Trigger on merge to main branch
   - Use Tailscale API or `tailscale/gitops-acl-action`

3. **Validation and Testing**
   - Pre-commit hooks to validate ACL syntax
   - CI checks for ACL policy correctness
   - Dry-run mode to preview changes

## Benefits

- **Audit Trail**: All ACL changes tracked in Git history
- **Review Process**: ACL changes go through PR review
- **Disaster Recovery**: ACL config backed up in Git
- **Infrastructure as Code**: Network policies defined alongside cluster config
- **Automation**: Reduce manual configuration errors

## Implementation Checklist

- [ ] Create `tailscale/` directory for ACL configuration
- [ ] Export current ACL policy from Tailscale admin console
- [ ] Set up GitHub Actions workflow for ACL updates
- [ ] Configure Tailscale OAuth client for CI/CD access
- [ ] Add pre-commit hooks for ACL validation
- [ ] Document ACL update process in README
- [ ] Test ACL updates in non-production environment
- [ ] Enable ACL GitOps for production cluster

## References

- [Tailscale GitOps ACL Action](https://github.com/tailscale/gitops-acl-action)
- [Tailscale ACL Documentation](https://tailscale.com/kb/1018/acls/)
- [HuJSON Format](https://github.com/tailscale/hujson)

## Related

This supports the infrastructure work for:
- Multi-control-plane HA setup
- Cross-pod network policies via Tailscale
- Automated cluster provisioning with Foundry
