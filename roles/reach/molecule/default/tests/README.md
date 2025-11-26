# Repository Clone Unit Tests

This directory contains testinfra-based unit tests for the reach role, specifically focusing on repository cloning behavior with different `sysinit_var` configurations.

## Test Files

### `test_repo_clone.py`

Tests the repository cloning logic in `roles/sysinit/tasks/tools/reach/repos.yml` with three primary scenarios:

#### Test Cases

1. **`test_repo_clone_continues_on_failure_with_molecule_converge`**
   - **Purpose**: Verify that the playbook continues when `sysinit_var` is set to `"molecule_converge"`
   - **Expected Behavior**: Repository cloning tasks are skipped, but the playbook continues successfully
   - **Related Code**: Tasks with `when: sysinit_var | default('') != 'molecule_converge'` condition

2. **`test_repo_clone_fails_with_custom_error_when_sysinit_var_not_set`**
   - **Purpose**: Verify that custom error messages are displayed when cloning fails in production
   - **Expected Behavior**: When `sysinit_var` is NOT `"molecule_converge"` and repository cloning fails, the playbook should fail with a detailed error message
   - **Related Code**: Lines 67-81 in `repos.yml` - the "Check for repository clone failures" task
   - **Error Message Includes**:
     - SSH key configuration issues
     - Repository access problems
     - Network connectivity issues
     - Actual error output from the clone operation

3. **`test_repo_clone_succeeds_with_rc_zero`**
   - **Purpose**: Verify that successful repository cloning (rc=0) allows the playbook to continue
   - **Expected Behavior**: When cloning succeeds with return code 0, no failure is triggered
   - **Related Code**: Verifies the `repos_output.rc != 0` condition in the fail task

#### Additional Tests

- **`test_repos_yml_task_structure`**: Validates the overall structure and error handling logic
- **`test_molecule_converge_skips_git_operations`**: Confirms git operations are bypassed in test mode
- **`test_molecule_converge_conditional_tasks`**: Parametrized test verifying each task has proper conditions

## Running the Tests

### Run all molecule tests for the reach scenario:

```bash
cd /home/kedwards/projects/rsysinit/main/roles/sysinit
molecule test -s reach
```

### Run only the verify phase (which includes these tests):

```bash
molecule verify -s reach
```

### Run specific test file:

```bash
pytest molecule/reach/tests/test_repo_clone.py -v
```

## Test Environment

These tests run in Docker containers as defined in `molecule.yml`:
- **Platforms**: Fedora (latest) and Ubuntu 22.04
- **Mode**: `sysinit_var` is set to `"molecule_converge"` to skip actual git operations
- **Base Directory**: `/tmp/test-withreach` (overridden for testing)

## Understanding the Logic

The repository cloning logic uses a pattern to handle both test and production environments:

```yaml
# Production: Clone repositories and fail on errors
when: sysinit_var | default('') != 'molecule_converge'

# The clone task uses ignore_errors to continue
ignore_errors: true
register: repos_output

# Then explicitly check for failures with detailed error message
- name: Check for repository clone failures
  ansible.builtin.fail:
    msg: |
      Failed to clone one or more repositories...
  when:
    - sysinit_var | default('') != 'molecule_converge'
    - repos_output.rc is defined
    - repos_output.rc != 0
```

This approach provides:
1. **Graceful test execution**: Tests don't fail due to missing git repositories
2. **Clear error messages**: Production failures provide actionable troubleshooting steps
3. **Explicit failure handling**: Rather than letting git failures propagate, we catch and explain them

## Test Dependencies

- **testinfra**: Python testing framework for infrastructure
- **pytest**: Test runner
- **molecule**: Ansible testing framework
- **docker**: Container runtime for test environments

Install test dependencies:

```bash
pip install molecule molecule-docker testinfra pytest
```

## Troubleshooting

### Tests fail to read repos.yml

The tests verify the task file structure by reading the actual `repos.yml` file. The path is determined dynamically from the `MOLECULE_PROJECT_DIRECTORY` environment variable, which molecule sets automatically. If running tests outside of molecule, the path is calculated relative to the test file location.

The tests look for the file at:
```python
PROJECT_ROOT = os.environ.get(
    'MOLECULE_PROJECT_DIRECTORY',
    os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../..'))
)
REPOS_YML_PATH = os.path.join(
    PROJECT_ROOT, 'roles/sysinit/tasks/tools/reach/repos.yml'
)
```

### Molecule not finding the tests

Ensure your `molecule.yml` specifies testinfra as the verifier if you want to run these Python tests alongside the Ansible verify playbook:

```yaml
verifier:
  name: testinfra
  options:
    v: 1
```

Note: The current configuration uses Ansible as the verifier, so these tests must be run separately with pytest.

## Related Files

- `../repos.yml`: The main task file being tested
- `../molecule.yml`: Molecule configuration for the reach scenario
- `../verify.yml`: Ansible-based verification tasks
- `../converge.yml`: Main playbook for the reach scenario
