#!/usr/bin/env bash
# SkyTunnel — CloudFormation template validation
# Validates the CF template syntax and optionally runs cfn-lint.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="${REPO_ROOT}/cloudformation/skytunnel-stack.yaml"
PARAMS="${REPO_ROOT}/cloudformation/params/example.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; ((FAIL++)); }

echo "=== SkyTunnel Template Validation ==="
echo ""

# --- Check template exists ---
if [[ ! -f "$TEMPLATE" ]]; then
    fail "Template not found: $TEMPLATE"
    exit 1
fi

# --- AWS CLI validation ---
echo "CloudFormation validate-template:"
if command -v aws &>/dev/null; then
    if aws cloudformation validate-template \
        --template-body "file://${TEMPLATE}" \
        --output text > /dev/null 2>&1; then
        pass "Template syntax valid"
    else
        fail "Template syntax invalid"
        aws cloudformation validate-template \
            --template-body "file://${TEMPLATE}" 2>&1 || true
    fi
else
    echo -e "  ${YELLOW}SKIP${NC}  AWS CLI not installed"
fi
echo ""

# --- cfn-lint (optional) ---
echo "cfn-lint:"
if command -v cfn-lint &>/dev/null; then
    if cfn-lint "$TEMPLATE" 2>&1; then
        pass "cfn-lint passed"
    else
        fail "cfn-lint found issues"
    fi
else
    echo -e "  ${YELLOW}SKIP${NC}  cfn-lint not installed (pip install cfn-lint)"
fi
echo ""

# --- Parameter file validation ---
echo "Parameter file:"
if [[ -f "$PARAMS" ]]; then
    if python3 -c "import json; json.load(open('${PARAMS}'))" 2>/dev/null; then
        pass "example.json is valid JSON"
    else
        fail "example.json is not valid JSON"
    fi

    # Check that all required params from template are in the example file
    if command -v aws &>/dev/null; then
        TEMPLATE_PARAMS=$(aws cloudformation validate-template \
            --template-body "file://${TEMPLATE}" \
            --query 'Parameters[].ParameterKey' \
            --output text 2>/dev/null | tr '\t' '\n' | sort)
        EXAMPLE_PARAMS=$(python3 -c "
import json
params = json.load(open('${PARAMS}'))
for p in params:
    print(p['ParameterKey'])
" 2>/dev/null | sort)

        MISSING=$(comm -23 <(echo "$TEMPLATE_PARAMS") <(echo "$EXAMPLE_PARAMS") | tr '\n' ', ' | sed 's/,$//')
        if [[ -z "$MISSING" ]]; then
            pass "All template parameters present in example.json"
        else
            fail "Missing parameters in example.json: $MISSING"
        fi
    fi
else
    fail "Parameter file not found: $PARAMS"
fi
echo ""

# --- Summary ---
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
