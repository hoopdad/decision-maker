#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=source-env.sh
source "$SCRIPT_DIR/source-env.sh"

usage() {
    cat <<'EOF'
Usage:
  ./run-workflow.sh [options]

Connection options:
  -g, --resource-group <name>  Azure resource group containing the VM
  -n, --vm-name <name>        Azure Linux VM name
  -d, --remote-dir <path>     Destination on the VM
  -s, --subscription <id>     Azure subscription ID or name
  -u, --local-user <name>     VM local user
  -i, --private-key-file <path>
                                WSL path to the VM private key
      --private-ip            Connect through the VM's private IP
  -h, --help                  Show this help

Values are loaded from .env. Command-line options override the loaded values.

Example:
  source ./source-env.sh
  ./run-workflow.sh

Prerequisites:
  - Run "az login" locally before starting this script.
  - Install the Azure CLI SSH extension with "az extension add --name ssh".
  - Run setup-vm.sh once to install the required software on the VM.
  - The VM must have Python, the Python venv module, Azure CLI, and an active
    Azure CLI login.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

RESOURCE_GROUP=${AZURE_RESOURCE_GROUP:-}
VM_NAME=${AZURE_VM_NAME:-}
REMOTE_DIR=${VM_REMOTE_DIR:-}
SUBSCRIPTION=${AZURE_SUBSCRIPTION_ID:-}
LOCAL_USER=${VM_LOCAL_USER:-}
PRIVATE_KEY_FILE=${VM_PRIVATE_KEY_FILE:-}
PREFER_PRIVATE_IP=${VM_PREFER_PRIVATE_IP:-false}

while (($# > 0)); do
    case "$1" in
        -g|--resource-group)
            (($# >= 2)) || die "$1 requires a value."
            RESOURCE_GROUP=$2
            shift 2
            ;;
        -n|--vm-name)
            (($# >= 2)) || die "$1 requires a value."
            VM_NAME=$2
            shift 2
            ;;
        -d|--remote-dir)
            (($# >= 2)) || die "$1 requires a value."
            REMOTE_DIR=$2
            shift 2
            ;;
        -s|--subscription)
            (($# >= 2)) || die "$1 requires a value."
            SUBSCRIPTION=$2
            shift 2
            ;;
        -u|--local-user)
            (($# >= 2)) || die "$1 requires a value."
            LOCAL_USER=$2
            shift 2
            ;;
        -i|--private-key-file)
            (($# >= 2)) || die "$1 requires a value."
            PRIVATE_KEY_FILE=$2
            shift 2
            ;;
        --private-ip)
            PREFER_PRIVATE_IP=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$RESOURCE_GROUP" ]] || die '--resource-group is required.'
[[ -n "$VM_NAME" ]] || die '--vm-name is required.'
[[ -n "$LOCAL_USER" ]] || die '--local-user cannot be empty.'
[[ -n "$REMOTE_DIR" ]] || die '--remote-dir cannot be empty.'
[[ "$PREFER_PRIVATE_IP" == true || "$PREFER_PRIVATE_IP" == false ]] ||
    die 'VM_PREFER_PRIVATE_IP must be "true" or "false".'
[[ "$REMOTE_DIR" =~ ^[A-Za-z0-9_./-]+$ ]] ||
    die 'The remote directory may contain only letters, numbers, ".", "_", "/", and "-".'

if [[ "$PRIVATE_KEY_FILE" == "~/"* ]]; then
    PRIVATE_KEY_FILE="$HOME/${PRIVATE_KEY_FILE:2}"
fi
[[ -f "$PRIVATE_KEY_FILE" ]] || die "Private key not found: $PRIVATE_KEY_FILE"

for command_name in az ssh scp awk mktemp; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command not found: $command_name"
done

PYTHON_FILE="$SCRIPT_DIR/workflow.py"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"
ENV_FILE="$SCRIPT_DIR/.env"

[[ -f "$PYTHON_FILE" ]] || die "File not found: $PYTHON_FILE"
[[ -f "$REQUIREMENTS_FILE" ]] || die "File not found: $REQUIREMENTS_FILE"
[[ -f "$ENV_FILE" ]] || die "File not found: $ENV_FILE"

AZURE_GLOBAL_ARGS=()
if [[ -n "$SUBSCRIPTION" ]]; then
    AZURE_GLOBAL_ARGS+=(--subscription "$SUBSCRIPTION")
fi

az account show "${AZURE_GLOBAL_ARGS[@]}" --output none >/dev/null 2>&1 ||
    die 'Azure CLI is not authenticated. Run "az login" and try again.'

az extension show --name ssh --output none >/dev/null 2>&1 ||
    die 'Azure CLI SSH extension is missing. Run "az extension add --name ssh".'

TEMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

SSH_CONFIG="$TEMP_DIR/sshconfig"
SSH_PRIVATE_KEY="$TEMP_DIR/private_key"
cp -- "$PRIVATE_KEY_FILE" "$SSH_PRIVATE_KEY"
chmod 600 "$SSH_PRIVATE_KEY"

SSH_CONFIG_ARGS=(
    --resource-group "$RESOURCE_GROUP"
    --name "$VM_NAME"
    --local-user "$LOCAL_USER"
    --private-key-file "$SSH_PRIVATE_KEY"
    --file "$SSH_CONFIG"
    --overwrite
    --only-show-errors
)
SSH_CONFIG_ARGS+=("${AZURE_GLOBAL_ARGS[@]}")
if [[ "$PREFER_PRIVATE_IP" == true ]]; then
    SSH_CONFIG_ARGS+=(--prefer-private-ip)
fi

printf 'Creating an Azure SSH configuration for %s as %s...\n' \
    "$VM_NAME" "$LOCAL_USER"
az ssh config "${SSH_CONFIG_ARGS[@]}"

SSH_HOST=$(awk '$1 == "Host" && $2 != "*" { print $2; exit }' "$SSH_CONFIG")
[[ -n "$SSH_HOST" ]] || die 'Azure CLI did not create a usable SSH host entry.'

printf 'Preparing %s on %s...\n' "$REMOTE_DIR" "$VM_NAME"
ssh -F "$SSH_CONFIG" "$SSH_HOST" "mkdir -p -- '$REMOTE_DIR'"

printf 'Copying workflow.py, requirements.txt, and .env...\n'
scp -F "$SSH_CONFIG" \
    "$PYTHON_FILE" \
    "$REQUIREMENTS_FILE" \
    "$ENV_FILE" \
    "$SSH_HOST:$REMOTE_DIR/"

printf 'Installing requirements and running workflow.py...\n'
ssh -F "$SSH_CONFIG" "$SSH_HOST" "bash -s -- '$REMOTE_DIR'" <<'REMOTE_SCRIPT'
set -euo pipefail

remote_dir=$1
cd -- "$remote_dir"

if [[ ! -f .env ]]; then
    printf 'Error: The transferred .env file is missing.\n' >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source ./.env
set +a

if command -v python3 >/dev/null 2>&1; then
    python_bin=python3
elif command -v python >/dev/null 2>&1; then
    python_bin=python
else
    printf 'Error: Python is not installed on the VM.\n' >&2
    exit 1
fi

if ! command -v az >/dev/null 2>&1; then
    printf 'Error: Azure CLI is required on the VM by AzureCliCredential.\n' >&2
    exit 1
fi

if ! az account get-access-token \
    --resource https://management.azure.com/ \
    --output none >/dev/null 2>&1; then
    printf 'Error: Azure CLI is not authenticated on the VM.\n' >&2
    printf 'Run "az login" or "az login --identity" on the VM, then retry.\n' >&2
    exit 1
fi

if [[ ! -x .venv/bin/python ]]; then
    if ! "$python_bin" -m venv .venv; then
        printf 'Error: Could not create a virtual environment. Install the Python venv package on the VM.\n' >&2
        exit 1
    fi
fi

.venv/bin/python -m pip install --requirement requirements.txt

echo ""
echo ""
echo ""
echo "***** BEGIN DEMO HERE *****"

exec .venv/bin/python workflow.py
REMOTE_SCRIPT
