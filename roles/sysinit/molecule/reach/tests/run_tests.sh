#!/bin/bash
# Helper script to run the repository clone unit tests
# Usage: ./run_tests.sh [options]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOLECULE_DIR="$(dirname "$SCRIPT_DIR")"
ROLE_DIR="$(dirname "$MOLECULE_DIR")/$(basename "$(dirname "$MOLECULE_DIR")")"

echo "Repository Clone Unit Tests Runner"
echo "==================================="
echo ""

# Check if running inside molecule or standalone
if [ -n "$MOLECULE_INVENTORY_FILE" ]; then
    echo "✓ Running inside molecule test environment"
    echo "  Inventory: $MOLECULE_INVENTORY_FILE"
else
    echo "⚠ Warning: MOLECULE_INVENTORY_FILE not set"
    echo "  These tests are designed to run within a molecule test environment."
    echo "  To run the full test suite:"
    echo "    cd $ROLE_DIR"
    echo "    molecule test -s reach"
    echo ""
    echo "  Or to verify an existing instance:"
    echo "    molecule converge -s reach"
    echo "    molecule verify -s reach"
    echo ""
    exit 1
fi

echo ""
echo "Running pytest..."
echo ""

# Run pytest with verbose output
cd "$SCRIPT_DIR"
pytest test_repo_clone.py -v "$@"

echo ""
echo "✓ Tests completed"
