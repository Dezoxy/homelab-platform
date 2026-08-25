# Validation Checks

This document describes the non-deploying validation gates used before a
change is merged. The implementation sources of truth are:

- [`.pre-commit-config.yaml`](../.pre-commit-config.yaml) for local hook definitions
- [`Makefile`](../Makefile) for local setup and full validation commands
- [`.github/workflows/`](../.github/workflows) for pull-request checks

Operational deploy, image build, maintenance, notification, and Renovate merge
workflows are described in [ci-workflows.md](ci-workflows.md); they are not
validation gates covered here.

## Quick Start

```bash
make bootstrap   # one-time setup: Python tools, git hooks, TFLint, and Packer
git commit       # runs the commit-stage hooks for staged matching files
git push         # runs slower push-stage hooks for matching pushed changes
make ci          # runs the complete local validation baseline
```

## Where Checks Run

| Context | Trigger | Scope | Purpose |
|---|---|---|---|
| Commit-stage hooks | `git commit` | Staged files that match each hook | Fast feedback before recording a commit |
| Push-stage hooks | `git push` | Triggered by matching changes; validates the relevant component | Catch slower lint, policy, and test failures before CI |
| Full local baseline | `make ci` | All tracked files plus all push-stage checks | Final local validation before opening or updating a PR |
| Diff-scoped PR checks | Pull request update | Files changed in the PR; full scope when checker configuration changes | Avoid rerunning independent checks on unaffected files |
| Subsystem PR checks | Pull request update affecting a subsystem | Complete affected Ansible, Packer, Terraform, or security scope | Cover shared variables, modules, roles, and security policy |
| Terraform plan | Pull request update affecting Terraform inputs | Every managed Terraform stack | Validate a read-only live plan through Tailscale and Proxmox access |

## Local Tool Setup

| Step | What it does | When to run it |
|---|---|---|
| `make setup` | Creates `.venv`, installs pinned Ansible, `ansible-lint`, and Checkov, then installs Ansible collections | After Python dependency or Ansible collection pin changes, or on first setup |
| `make setup-hooks` | Installs both the `pre-commit` and `pre-push` git hooks configured by pre-commit | After cloning or when hooks are missing |
| `make install-tools` | Downloads pinned TFLint and Packer binaries into `.local/bin/` | After local binary pin changes, or on first setup |
| `make bootstrap` | Runs all three setup steps | Recommended initial repository setup |

Shared tool pins are maintained in
[`scripts/ci/versions.sh`](../scripts/ci/versions.sh). The wrappers use
Make-managed installations and report the relevant setup command when a
required tool is unavailable.

## Commit-Stage Hooks

These hooks run automatically on `git commit`. File-changing hooks require the
updated files to be reviewed and staged again before completing the commit.

| Check | What it checks | Behavior |
|---|---|---|
| `trailing-whitespace` | Trailing spaces in text files | Removes trailing whitespace |
| `end-of-file-fixer` | Missing or excessive end-of-file newline | Normalizes the file ending |
| `check-yaml --unsafe` | YAML parsing, including repository files using Ansible-specific YAML tags | Fails malformed YAML |
| `check-json` | JSON syntax | Fails malformed JSON |
| `check-toml` | TOML syntax | Fails malformed TOML |
| `check-added-large-files --enforce-all` | Files large enough to indicate an accidentally committed artifact | Fails the commit |
| `check-case-conflict` | File names that collide on case-insensitive filesystems | Fails the commit |
| `check-merge-conflict` | Unresolved merge conflict markers | Fails the commit |
| `detect-private-key` | Common private-key material | Fails the commit |
| `check-executables-have-shebangs` | Executable scripts without an interpreter header | Fails the commit |
| `check-shebang-scripts-are-executable` | Scripts with a shebang but without executable permissions | Fails the commit; Ansible role payload files are excluded because Ansible controls their installed mode |
| `mixed-line-ending --fix=lf` | Mixed CRLF/LF line endings | Converts affected text to LF |
| `gitleaks` | Credentials and token patterns configured by [`.gitleaks.toml`](../.gitleaks.toml) | Fails potential secret exposure |
| `shellcheck` | Shell script correctness and common unsafe constructs at warning severity or above | Fails shell diagnostics |
| `ruff-check --fix` | Python lint and import issues | Fixes supported issues and fails remaining diagnostics |
| `ruff-format` | Python formatting policy | Rewrites nonconforming files |
| `actionlint` | GitHub Actions workflow syntax, expressions, and embedded shell validation | Fails invalid workflow definitions |
| `terraform_fmt` | Terraform source formatting | Rewrites nonconforming `.tf` files |
| `ssh-trust-metadata` | SSH known-host inventory and attestation consistency | Validates the complete trust metadata relationship when related files change |
| `ansible-lint` | Playbooks, roles, and Ansible configuration | Validates all of `ansible/` when Ansible files, its wrapper, or shared versions change |
| `packer-fmt` | Committed Packer HCL formatting | Checks tracked `*.pkr.hcl` files when Packer files, its wrapper, or shared versions change; ignored local variable files are not inspected |

## Push-Stage Hooks

These checks run automatically on `git push`. They are deliberately slower and
run only when the pushed change matches their component.

| Check | Triggered by | What it checks |
|---|---|---|
| `tflint` | Terraform, TFLint configuration, Terraform stack matrix logic, its wrapper, or shared version changes | Initializes pinned TFLint plugins and lints every managed Terraform stack |
| `checkov` | Terraform, its wrapper, or shared version changes | Scans `infra-proxmox/terraform/` for infrastructure security policy violations; `CKV_TF_1` is skipped for the repository's intentional local-module use |

## Full Local Baseline

`make ci` is the full pre-PR command. It is non-deploying and does not run a
Terraform plan or contact Proxmox.

It executes these steps in order:

1. `make setup` ensures Python and Ansible validation dependencies are present.
2. `make install-tools` ensures pinned TFLint and Packer binaries are present.
3. `pre-commit run --all-files` runs every commit-stage hook over all tracked files.
4. `pre-commit run --hook-stage pre-push --all-files` forces every push-stage hook to run.

## Pull-Request Checks

GitHub Actions repeats validation in a clean runner environment. Fast
file-local checks use the PR diff, while subsystem checks deliberately validate
the full affected subsystem.

| Workflow | When it runs | Steps and coverage |
|---|---|---|
| `CI / Pre-commit Fast Checks` | Every pull request | Installs pre-commit and runs file hygiene, Python, and SSH trust metadata hooks on changed files. If its workflow or `.pre-commit-config.yaml` changes, it validates all tracked files instead. |
| `CI / Actions Lint` | Workflow files or the Actionlint version pin change | Installs pinned Actionlint and ShellCheck, then checks changed workflow files. If its own workflow or the Actionlint pin changes, it checks all workflows. |
| `CI / ShellCheck` | Shell scripts or its workflow change | Installs ShellCheck and checks changed shell scripts. If its workflow changes, it checks all tracked shell scripts. |
| `CI / Ansible Lint` | Ansible, SSH trust validation, shared version, or workflow inputs change | Validates SSH trust metadata, installs pinned Ansible tooling and collections, then runs `ansible-lint` over the complete Ansible tree. |
| `CI / Python Unit Tests` | Telegram reader application, test wrapper, or workflow changes | Runs the Telegram reader unit test suite. |
| `CI / Packer Validate` | Packer templates, shared versions, or workflow changes | Validates the Ubuntu template matrix with pinned Packer: `fmt -check`, `init`, and `validate`, using disposable validation inputs rather than building images. |
| `CI / Terraform Lint` | Terraform, TFLint, stack matrix, shared versions, or workflow changes | Discovers managed stacks, initializes TFLint plugins, lints each stack, and runs Checkov over the Terraform tree. |
| `CI / Terraform Plan` | Manual dispatch only | Discovers managed stacks, fetches runtime secrets, joins Tailscale, checks Proxmox reachability, then runs `fmt -check`, `init`, `validate`, and read-only `plan` for each stack and uploads plan artifacts. This workflow is not triggered by PRs or pushes. |
| `CI / Secret Scan` | Pull request validation | Checks the repository checkout with Gitleaks for committed secrets. |
| `CI / Trivy Image Scan` | Container image references in Ansible host variables or role defaults, or its workflow/extractor change | **Currently skipped** (the `trivy` job is gated on repo variable `TRIVY_ENABLED`, unset → skipped — kept, not removed; re-enable by setting `TRIVY_ENABLED=true`). Scans changed pinned images for fixed `HIGH` or `CRITICAL` vulnerabilities; checker changes validate the complete pinned-image inventory. Daily and manual full-inventory scans run outside PR validation. |

### Why Some PR Checks Are Not Diff-Only

- Ansible roles and variables can affect playbooks outside the changed file, so
  `ansible-lint` validates the full Ansible tree.
- Terraform stacks share modules, policy, and discovery logic, so TFLint,
  Checkov, and the plan job retain complete impacted-system coverage.
- Packer changes can affect a template matrix, so template validation covers
  each supported image variant.
- Secret scanning is repository-level protection and is not reduced to a
  formatter-style changed-file check.
- Container image vulnerabilities can be disclosed after a pin is merged, so
  Trivy also scans the complete deployed-image inventory daily.

## Handling Failures

| Failure type | Action |
|---|---|
| A formatter changes files during commit | Review the changes, stage them, and commit again |
| `.venv` validation tool is missing | Run `make setup`, or `make bootstrap` on a new checkout |
| TFLint or Packer is missing or version-mismatched | Run `make install-tools` |
| SSH trust metadata fails | Review [ssh.md](ssh.md) and update the attestation or known-host input deliberately; do not bypass the trust check |
| Terraform lint or Checkov fails | Fix the Terraform source or document an intentional policy exception before adding a skip |
| Terraform plan fails | Inspect plan output and connectivity/secrets setup; the PR workflow must not be replaced with an apply operation |
