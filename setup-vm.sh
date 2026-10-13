#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=source-env.sh
source "$SCRIPT_DIR/source-env.sh"

usage() {
    cat <<'EOF'
Usage:
  ./setup-vm.sh [options]

Connection options:
  -g, --resource-group <name>  Azure resource group containing the VM
  -n, --vm-name <name>        Azure Linux VM name
  -s, --subscription <id>     Azure subscription ID or name
  -u, --local-user <name>     VM local user
  -i, --private-key-file <path>
                                WSL path to the VM private key
      --private-ip            Connect through the VM's private IP
      --login-with-managed-identity
                                Run "az login --identity" on the VM
  -h, --help                  Show this help

Values are loaded from .env. Command-line options override the loaded values.

Examples:
  source ./source-env.sh
  ./setup-vm.sh
  ./setup-vm.sh -g another-resource-group -n another-vm

The remote user must be root or have passwordless sudo access. This script
supports apt, dnf, tdnf, and yum based Linux distributions.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

RESOURCE_GROUP=${AZURE_RESOURCE_GROUP:-}
VM_NAME=${AZURE_VM_NAME:-}
SUBSCRIPTION=${AZURE_SUBSCRIPTION_ID:-}
LOCAL_USER=${VM_LOCAL_USER:-}
PRIVATE_KEY_FILE=${VM_PRIVATE_KEY_FILE:-}
PREFER_PRIVATE_IP=${VM_PREFER_PRIVATE_IP:-false}
LOGIN_WITH_MANAGED_IDENTITY=${VM_LOGIN_WITH_MANAGED_IDENTITY:-false}

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
        --login-with-managed-identity)
            LOGIN_WITH_MANAGED_IDENTITY=true
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
[[ "$PREFER_PRIVATE_IP" == true || "$PREFER_PRIVATE_IP" == false ]] ||
    die 'VM_PREFER_PRIVATE_IP must be "true" or "false".'
[[ "$LOGIN_WITH_MANAGED_IDENTITY" == true || "$LOGIN_WITH_MANAGED_IDENTITY" == false ]] ||
    die 'VM_LOGIN_WITH_MANAGED_IDENTITY must be "true" or "false".'

if [[ "$PRIVATE_KEY_FILE" == "~/"* ]]; then
    PRIVATE_KEY_FILE="$HOME/${PRIVATE_KEY_FILE:2}"
fi
[[ -f "$PRIVATE_KEY_FILE" ]] || die "Private key not found: $PRIVATE_KEY_FILE"

for command_name in az ssh awk mktemp; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command not found: $command_name"
done

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

printf 'Installing VM dependencies on %s...\n' "$VM_NAME"
ssh -F "$SSH_CONFIG" "$SSH_HOST" \
    "bash -s -- '$LOGIN_WITH_MANAGED_IDENTITY'" <<'REMOTE_SCRIPT'
set -euo pipefail

login_with_managed_identity=$1
installer_file=''
test_venv=''

cleanup() {
    if [[ -n "$installer_file" ]]; then
        rm -f -- "$installer_file"
    fi
    if [[ -n "$test_venv" ]]; then
        rm -rf -- "$test_venv"
    fi
}
trap cleanup EXIT

SUDO=()
if ((EUID != 0)); then
    command -v sudo >/dev/null 2>&1 ||
        {
            printf 'Error: Root access or sudo is required on the VM.\n' >&2
            exit 1
        }
    sudo -n true >/dev/null 2>&1 ||
        {
            printf 'Error: The remote user needs passwordless sudo access.\n' >&2
            exit 1
        }
    SUDO=(sudo)
fi

install_azure_cli_debian() {
    installer_file=$(mktemp)
    curl --fail --silent --show-error --location \
        https://aka.ms/InstallAzureCLIDeb \
        --output "$installer_file"
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive bash "$installer_file"
    rm -f -- "$installer_file"
    installer_file=''
}

install_azure_cli_rpm() {
    local package_manager=$1

    "${SUDO[@]}" rpm --import https://packages.microsoft.com/keys/microsoft.asc
    cat <<'AZURE_CLI_REPO' |
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
AZURE_CLI_REPO
        "${SUDO[@]}" tee /etc/yum.repos.d/azure-cli.repo >/dev/null
    "${SUDO[@]}" "$package_manager" install -y azure-cli
}

if command -v apt-get >/dev/null 2>&1; then
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y python3 python3-pip python3-venv curl ca-certificates
    if ! command -v az >/dev/null 2>&1; then
        install_azure_cli_debian
    fi
else
    package_manager=''
    for candidate in dnf tdnf yum; do
        if command -v "$candidate" >/dev/null 2>&1; then
            package_manager=$candidate
            break
        fi
    done

    if [[ -z "$package_manager" ]]; then
        printf 'Error: Supported package manager not found (apt, dnf, tdnf, or yum).\n' >&2
        exit 1
    fi

    "${SUDO[@]}" "$package_manager" install -y \
        python3 python3-pip curl ca-certificates
    if ! command -v az >/dev/null 2>&1; then
        install_azure_cli_rpm "$package_manager"
    fi
fi

command -v python3 >/dev/null 2>&1 ||
    {
        printf 'Error: Python 3 installation could not be verified.\n' >&2
        exit 1
    }
python3 -m pip --version

test_venv=$(mktemp -d)
if ! python3 -m venv "$test_venv"; then
    printf 'Error: Python virtual environment support could not be verified.\n' >&2
    exit 1
fi
"$test_venv/bin/python" -m pip --version

command -v az >/dev/null 2>&1 ||
    {
        printf 'Error: Azure CLI installation could not be verified.\n' >&2
        exit 1
    }
az version --output none

if [[ "$login_with_managed_identity" == true ]]; then
    printf 'Authenticating Azure CLI with the VM managed identity...\n'
    az login --identity --allow-no-subscriptions --output none
fi

if az account get-access-token \
    --resource https://management.azure.com/ \
    --output none >/dev/null 2>&1; then
    printf 'Azure CLI authentication is ready on the VM.\n'
else
    printf 'VM dependencies are installed, but Azure CLI is not authenticated.\n' >&2
    printf 'Run "az login --identity" or another appropriate "az login" command on the VM.\n' >&2
fi

printf 'VM dependency setup completed successfully.\n'
REMOTE_SCRIPT
