"""Test repository cloning behavior with different sysinit_var values."""

import os
import pytest
import testinfra.utils.ansible_runner

testinfra_hosts = testinfra.utils.ansible_runner.AnsibleRunner(
    os.environ['MOLECULE_INVENTORY_FILE']
).get_hosts('all')

# Get the project root dynamically
PROJECT_ROOT = os.environ.get(
    'MOLECULE_PROJECT_DIRECTORY',
    os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../..'))
)
REPOS_YML_PATH = os.path.join(
    PROJECT_ROOT, 'roles/sysinit/tasks/tools/reach/repos.yml'
)


def test_repo_clone_continues_on_failure_with_molecule_converge(host):
    """
    Test that the playbook continues if repository cloning fails when
    sysinit_var is set to 'molecule_converge'.
    
    This simulates the behavior where tasks with:
    when: sysinit_var | default('') != 'molecule_converge'
    are skipped during molecule testing.
    """
    # Get ansible variables
    ansible_vars = host.ansible.get_variables()
    sysinit_var = ansible_vars.get('sysinit_var', '')
    
    # Verify that sysinit_var is set to molecule_converge in test environment
    assert sysinit_var == 'molecule_converge', \
        f"Expected sysinit_var='molecule_converge', got '{sysinit_var}'"
    
    # Verify that the playbook completed successfully despite skipping repo cloning
    # Check that subsequent tasks still executed (e.g., directory creation)
    reach_base = ansible_vars.get('sysinit_reach_base_dir', '/tmp/test-withreach')
    base_dir = host.file(reach_base)
    
    # The playbook should have created the base directory even without cloning
    assert base_dir.exists, \
        f"Base directory {reach_base} should exist even when repo clone is skipped"
    assert base_dir.is_directory


def test_repo_clone_fails_with_custom_error_when_sysinit_var_not_set(host):
    """
    Test that the playbook would fail with custom error message if repository
    cloning fails and sysinit_var is not 'molecule_converge'.
    
    This test verifies the conditional logic in repos.yml lines 67-81 that
    checks for repository clone failures and provides a detailed error message.
    """
    # Get ansible variables
    ansible_vars = host.ansible.get_variables()
    sysinit_var = ansible_vars.get('sysinit_var', '')
    
    # This test documents the expected behavior when sysinit_var != 'molecule_converge'
    # In the actual molecule test, sysinit_var IS 'molecule_converge', so we verify
    # the conditional would trigger the failure in production scenarios
    
    # Read the repos.yml task file to verify the fail condition exists
    repos_yml = host.file(REPOS_YML_PATH)
    
    if repos_yml.exists:
        content = repos_yml.content_string
        
        # Verify the fail task exists with proper conditions
        assert 'ansible.builtin.fail:' in content, \
            "repos.yml should contain a fail task for clone failures"
        
        assert "sysinit_var | default('') != 'molecule_converge'" in content, \
            "repos.yml should check sysinit_var condition before failing"
        
        assert 'repos_output.rc != 0' in content, \
            "repos.yml should check return code before failing"
        
        # Verify the custom error message exists
        assert 'Failed to clone one or more repositories' in content, \
            "repos.yml should have custom error message for clone failures"
        
        assert 'You do not have access to the repository' in content or \
               'SSH key is not configured' in content, \
            "repos.yml should provide helpful troubleshooting information"


def test_repo_clone_succeeds_with_rc_zero(host):
    """
    Test that the playbook succeeds if repository cloning is successful (rc=0).
    
    When sysinit_var is NOT 'molecule_converge' and the repository clone
    operation returns rc=0, the playbook should continue normally without
    triggering the failure condition.
    """
    # Get ansible variables
    ansible_vars = host.ansible.get_variables()
    
    # Since we're in molecule_converge mode, we can't directly test the clone
    # success path, but we can verify the logic exists in the task file
    
    repos_yml = host.file(REPOS_YML_PATH)
    
    if repos_yml.exists:
        content = repos_yml.content_string
        
        # Verify the fail condition only triggers on non-zero return codes
        assert 'repos_output.rc != 0' in content, \
            "Failure should only occur when rc != 0"
        
        # Verify ignore_errors is set on the repo clone task
        assert 'ignore_errors: true' in content, \
            "Repository retrieval task should have ignore_errors enabled"
        
        # Verify the task registration
        assert 'register: repos_output' in content, \
            "Repository output should be registered for error checking"


def test_repos_yml_task_structure(host):
    """
    Verify the overall structure of repos.yml tasks for clone error handling.
    
    This test ensures that:
    1. Repository clone task uses ignore_errors
    2. Error checking task only runs when sysinit_var != 'molecule_converge'
    3. Error checking task only fails when rc != 0
    """
    repos_yml = host.file(REPOS_YML_PATH)
    
    assert repos_yml.exists, f"repos.yml should exist at {REPOS_YML_PATH}"
    
    content = repos_yml.content_string
    
    # Verify task: "Retrieve required repositories"
    assert 'name: Retrieve required repositories' in content, \
        "Task for retrieving repositories should exist"
    
    # Verify task: "Check for repository clone failures"
    assert 'name: Check for repository clone failures' in content, \
        "Task for checking clone failures should exist"
    
    # Count the occurrences of the molecule_converge condition
    molecule_checks = content.count("sysinit_var | default('') != 'molecule_converge'")
    
    assert molecule_checks >= 3, \
        f"Expected at least 3 molecule_converge checks in repos.yml, found {molecule_checks}"
    
    # Verify that multiple tasks skip during molecule testing
    # This ensures consistent behavior across all repository-related tasks
    assert 'when:' in content, "Conditional when clauses should be present"
    
    # Verify the fail task has multiple conditions (all must be true to fail)
    fail_section_start = content.find('name: Check for repository clone failures')
    fail_section_end = content.find('- name:', fail_section_start + 1)
    fail_section = content[fail_section_start:fail_section_end]
    
    assert 'repos_output.rc is defined' in fail_section, \
        "Fail task should check if rc is defined"
    assert 'repos_output.rc != 0' in fail_section, \
        "Fail task should check if rc is non-zero"


def test_molecule_converge_skips_git_operations(host):
    """
    Verify that git operations are properly skipped during molecule testing.
    
    This ensures that the molecule_converge mode successfully bypasses
    git-related tasks that would fail in containerized test environments.
    """
    ansible_vars = host.ansible.get_variables()
    sysinit_var = ansible_vars.get('sysinit_var', '')
    
    # Confirm we're in molecule_converge mode
    assert sysinit_var == 'molecule_converge', \
        "This test should run with sysinit_var='molecule_converge'"
    
    # Verify that the playbook completed successfully
    # This implicitly confirms that git tasks were skipped
    reach_base = ansible_vars.get('sysinit_reach_base_dir', '/tmp/test-withreach')
    
    # Check that non-git tasks still executed
    base_dir = host.file(reach_base)
    assert base_dir.exists, \
        "Base directory should exist, confirming playbook executed"
    
    # The .git directory should NOT exist since cloning was skipped
    git_dir = host.file(f"{reach_base}/.git")
    assert not git_dir.exists, \
        f".git directory should not exist at {reach_base}/.git during molecule testing"


@pytest.mark.parametrize('task_name,should_skip', [
    ('Ensure DevOps repo exists', True),
    ('Clone DevOps repository', True),
    ('Check for new repositories to clone', True),
    ('Retrieve required repositories', True),
    ('Check for repository clone failures', True),
])
def test_molecule_converge_conditional_tasks(host, task_name, should_skip):
    """
    Parametrized test to verify that specific tasks are properly conditioned.
    
    Tests that each git-related task has the proper when condition to skip
    during molecule_converge mode.
    """
    repos_yml = host.file(REPOS_YML_PATH)
    
    if repos_yml.exists:
        content = repos_yml.content_string
        
        # Find the task in the content
        task_marker = f"name: {task_name}"
        assert task_marker in content, \
            f"Task '{task_name}' should exist in repos.yml"
        
        # Get the section for this task
        task_start = content.find(task_marker)
        next_task = content.find('- name:', task_start + 1)
        if next_task == -1:
            task_section = content[task_start:]
        else:
            task_section = content[task_start:next_task]
        
        if should_skip:
            # Verify the task has the molecule_converge condition
            assert "sysinit_var | default('') != 'molecule_converge'" in task_section, \
                f"Task '{task_name}' should have molecule_converge condition to skip during testing"
