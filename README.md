# Workflow with a Decision Model

This is an example of using a decision model in a work flow.

```text
+--> Input Prompt --> Agent 1 --> Agent 2 --> Evaluator --> Decision -- success --> Done
                      |                                            |
                      +<------------- run again <------------------+
```

The results from Agent 1 and Agent 2 are evaluated against success
criteria, and the workflow repeats until success. Evaluator uses a
Foundry-hosted decision model, Microsoft-Decision-1.

The example is a litle fever-dream ridiculous, but illustrates the point.

In `workflow.py` look for `run_workflow`. Note the use of `HttpDecisionClient`
for the decision model as an API was not known to the author at time of writing.

Look for the keyword "instructions" (case-insensitive) to see agent instructions.

Below this line, the rest of this document was written by AI.

## How to run the demo

Run `workflow.py` in either of two places:

- **Locally** using your Azure CLI identity, when full connectivity to the
  Foundry models is available.
- **On a Foundry-proximal Azure VM** using the VM's managed identity. A
  proximal VM has the private network and DNS access needed to reach the
  Foundry endpoints.

Run the commands below from Bash or WSL.

## 1. Configure the example

Use `.env.template` as the reference for every supported setting and whether it
is always required, required for remote VM execution, or optional. Edit `.env`
before the first run. It contains the VM connection settings, Azure account
IDs, Foundry endpoints, model deployments, and request limits.

`.env` is committed and copied to the VM. Keep only non-secret configuration
in it—never add passwords, tokens, or private-key contents.

Load its values into your current shell with:

```bash
source ./source-env.sh
```

## 2A. Run locally

### Prerequisites

- Python 3 with virtual-environment support
- Azure CLI
- Network and private DNS access to the configured Foundry endpoints
- Foundry access for your Azure user

### Run

```bash
source ./source-env.sh

az login --tenant "$AZURE_TENANT_ID"
az account set --subscription "$AZURE_SUBSCRIPTION_ID"

python3 -m venv .venv
source .venv/bin/activate
python -m pip install --requirement requirements.txt
python workflow.py
```

## 2B. Run on the Foundry-proximal VM

### Prerequisites

On your workstation:

- WSL, Azure CLI, and OpenSSH
- The Azure CLI SSH extension
- The private key configured by `VM_PRIVATE_KEY_FILE` in `.env`
- Network access to the VM

On the VM:

- A system-assigned managed identity with Foundry access
- Private network and DNS access to the configured Foundry endpoints
- A local user with passwordless `sudo` for the initial setup

### Set up the VM once

```bash
source ./source-env.sh

az login --tenant "$AZURE_TENANT_ID"
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
az extension add --name ssh

./setup-vm.sh
```

The setup script installs Python, pip, virtual-environment support, and Azure
CLI. With `VM_LOGIN_WITH_MANAGED_IDENTITY=true`, it also runs
`az login --identity` on the VM.

### Run the workflow

```bash
./run-workflow.sh
```

The runner copies `workflow.py`, `requirements.txt`, and `.env` to the VM,
creates or reuses the remote virtual environment, installs dependencies, and
runs the workflow.

If the VM is reachable only through its private address, use `--private-ip`
for both commands:

```bash
./setup-vm.sh --private-ip
./run-workflow.sh --private-ip
```

## Overrides

Both VM scripts load `.env` automatically. Command-line options override its
VM connection values:

```bash
./run-workflow.sh \
  --resource-group another-resource-group \
  --vm-name another-vm \
  --local-user another-user \
  --private-key-file /mnt/c/Users/me/.ssh/another-key
```

See every option with:

```bash
./setup-vm.sh --help
./run-workflow.sh --help
```

## Troubleshooting

- **SSH permission denied:** verify the configured key with
  `ls -l "$VM_PRIVATE_KEY_FILE"` and confirm `VM_LOCAL_USER`.
- **Azure CLI is not authenticated on the VM:** rerun `./setup-vm.sh` with
  `VM_LOGIN_WITH_MANAGED_IDENTITY=true` in `.env`.
- **Foundry connection fails:** confirm the execution host resolves the
  Foundry endpoint to a private address and its identity has Foundry access.
- **Setup cannot use sudo:** the VM user needs passwordless `sudo` during
  setup.
