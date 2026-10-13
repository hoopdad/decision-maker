# Repository index

Small Python demo that runs a two-agent Microsoft Foundry workflow, reviews
agent output for idioms, and uses a Foundry-hosted Decision model to decide
whether output should be retried. It can run locally or on an existing Azure
Linux VM.

## Functional areas

- Project usage and architecture overview: `README.md`
- Workflow and Decision integration: `workflow.py` creates Foundry agents,
  validates Decision API responses, enforces local request admission, verifies
  private endpoint resolution, and runs the retry loop.
- Configuration reference: `.env.template` documents every supported Foundry,
  Decision, Azure, and VM setting; `.env` is local runtime configuration.
- Environment loading: `source-env.sh` exports `.env` values for Bash and child
  processes.
- Remote execution: `run-workflow.sh` copies the workflow, dependencies, and
  local `.env` to an Azure VM, prepares a remote virtual environment, and runs
  the demo.
- VM setup: `setup-vm.sh` installs and verifies Python, virtual-environment
  support, pip, and Azure CLI on an existing Azure Linux VM.
- Python dependencies: `requirements.txt` lists Agent Framework, Foundry, and
  Azure Identity packages. `workflow.py` also imports `httpx` directly.
- Repository housekeeping: `.gitignore` excludes local configuration,
  generated Python state, test artifacts, editor files, and VM helper output;
  `LICENSE` contains the MIT license.

## Technical layers

- `workflow.py` is the application entry point. Its implemented `v` coroutine
  authenticates with `DefaultAzureCredential`, creates the `casper`, `caveman`,
  and idiom-review agents, calls the Decision endpoint through
  `HttpDecisionClient`, and repeats agent output until the Decision model
  selects `Complete`.
- The Decision adapter in `workflow.py` owns request serialization, strict
  response-shape and probability validation, timeout handling, `Retry-After`
  backoff, bounded response reads, per-process admission control, and private
  RFC 1918 endpoint enforcement.
- `source-env.sh` is the shared configuration entry point for local shells and
  both VM scripts.
- `run-workflow.sh` is the remote deployment/execution entry point. It uses
  `az ssh config`, OpenSSH, and `scp`; it does not provision Azure resources.
- `setup-vm.sh` is the remote host preparation entry point. It supports apt,
  dnf, tdnf, and yum based Linux distributions and can authenticate Azure CLI
  with the VM managed identity.
- `.venv/` and `venv/` are generated local environment state, not source.

## Navigation

- Set up and run the demo: `README.md`
- Change agent prompts, workflow behavior, Decision requests, validation, or
  retry/admission behavior: `workflow.py`
- Review supported settings and requirement levels: `.env.template`
- Configure a local run or remote VM target: `.env`
- Export configuration into the current shell: `source-env.sh`
- Change Python packages: `requirements.txt`
- Change Azure VM transfer or launch behavior: `run-workflow.sh`
- Change Azure VM operating-system setup: `setup-vm.sh`
- Change generated-file exclusions: `.gitignore`
- Review licensing: `LICENSE`

## Conventions and tests

- Run Python dependencies in a virtual environment.
- Use environment variables for Foundry, Decision, Azure, and VM settings;
  `required_env` rejects missing or blank required values.
- Keep secrets, tokens, and private-key contents out of `.env`; the remote
  runner transfers that file to the VM.
- Foundry and Decision access use `DefaultAzureCredential`; local runs can use
  Azure CLI authentication, while Azure-hosted runs can use managed identity.
- The Decision endpoint must resolve only to private RFC 1918 addresses; the
  client disables redirects and proxy-derived environment settings.
- VM scripts use a protected temporary copy of the configured SSH private key
  and remove temporary files on exit.
- The current entry point calls an undefined `run_workflow` function instead of
  the implemented `v` coroutine, so `python workflow.py` does not currently
  reach the demo.
- `httpx` is a direct import in `workflow.py` but is not pinned explicitly in
  `requirements.txt`.
- No automated test suite or project-level lint configuration is present.

## Freshness

- Indexed 2026-10-13.
- Repository: `hoopdad/decision-maker`; branch: `main`; HEAD: `80d6058`
  (`Initial commit`).
- The worktree contains uncommitted changes. At index time, only `LICENSE` is
  tracked; the application, scripts, configuration reference, README,
  `.gitignore`, and this index are untracked or ignored.
- Source paths considered: `.env.template`, `.gitignore`,
  `.github/repo-index.md`, `LICENSE`, `README.md`, `requirements.txt`,
  `run-workflow.sh`, `setup-vm.sh`, `source-env.sh`, and `workflow.py`.
- Ignored local files such as `.env`, `my-vm.txt`, and generated virtual
  environments were not treated as source.
