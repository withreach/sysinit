# Reach-Specific Molecule Testing

This directory contains Molecule scenarios specifically designed to test the `reach` tool functionality within the sysinit role.

## Overview

The reach scenario focuses on testing:

1. **SSH Configuration**: SSH key generation, agent setup, and configuration
2. **Repository Management**: Git repository cloning and management
3. **Host Configuration**: Local development host entries in `/etc/hosts`
4. **Sudo Configuration**: Sudoers rules for reach development
5. **SELinux Configuration**: SELinux contexts and booleans for Docker containers
6. **User Preferences**: Dotfiles and profile configuration

## Test Platforms

- **Fedora Latest**: Tests SELinux functionality and Red Hat family compatibility
- **Ubuntu 22.04**: Tests Debian family compatibility and non-SELinux scenarios

## Testing Scenarios

### Prepare Phase
- Installs required packages (git, SSH, sudo, Python)
- Creates test directory structures
- Sets up mock repository scripts
- Generates dummy SSH keys
- Configures git with test credentials

### Converge Phase
- Runs the sysinit role with only the `reach` tool enabled
- Tests all reach-specific tasks and configurations

### Verify Phase
- Validates directory structure creation
- Checks SSH key generation and permissions
- Verifies hosts file entries
- Confirms sudoers configuration
- Tests git configuration
- Checks SELinux contexts (on Fedora)

### Side Effect Phase
- Tests idempotency (no changes on second run)
- Tests selective tag execution
- Verifies configuration file integrity
- Tests backup functionality
- Validates sudoers file syntax

## Running Tests

### Full Test Suite
```bash
# Run all tests for reach scenario
molecule test -s reach
```

### Individual Test Steps
```bash
# Create and prepare test environment
molecule create -s reach
molecule prepare -s reach

# Run the role
molecule converge -s reach

# Test idempotency
molecule idempotence -s reach

# Run verification tests
molecule verify -s reach

# Test side effects
molecule side-effect -s reach

# Clean up
molecule destroy -s reach
```

### Quick Syntax Check
```bash
molecule syntax -s reach
```

## Test Configuration

The reach scenario uses specific test variables:

```yaml
# Test-specific overrides
sysinit_reach_base_dir: "/tmp/test-withreach"
sysinit_reach_devops_repo_url: "https://github.com/withreach/reach-devops.git"
sysinit_reach_dev_hosts:
  - test.rch.local
  - api.test.rch.local
sysinit_var: molecule_converge  # Skip git operations in containers
```

## Expected Outcomes

✅ **SSH Configuration**: Keys generated with proper permissions
✅ **Repository Setup**: Mock repository structure created
✅ **Hosts File**: Development hosts added to `/etc/hosts`
✅ **Sudo Rules**: Sudoers configuration created and validated
✅ **SELinux**: Contexts applied (Fedora only)
✅ **User Config**: Profile settings and dotfiles deployed
✅ **Idempotency**: No changes on subsequent runs
✅ **Tag Selectivity**: Individual components can be run via tags

## Troubleshooting

### Common Issues

1. **SELinux Context Failures**: In containers, some SELinux operations may be limited
2. **SSH Agent Issues**: Containers don't have persistent SSH agents
3. **Git Operations**: Network operations are mocked to avoid external dependencies

### Debug Mode

Run with increased verbosity:
```bash
molecule --debug test -s reach
```

Or check specific task output:
```bash
molecule converge -s reach -- -vv
```

## Integration with CI/CD

This scenario is designed to run in containerized CI/CD environments and includes:

- Mock external dependencies
- Container-safe configurations
- Comprehensive test coverage
- Clear pass/fail indicators

## Contributing

When adding new reach functionality:

1. Update test variables in `molecule.yml`
2. Add verification steps in `verify.yml`
3. Include side effect tests in `side_effect.yml`
4. Update this README with new test scenarios
