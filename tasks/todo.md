# Renovate Coverage Expansion

- [x] Scope
  Expand Renovate coverage so it updates the dependency surfaces that are actually present in this repo, not just a subset of Ansible image vars.
- [x] Inventory
  Confirm which dependency sources are already covered by Renovate built-in managers and which need custom regex managers.
  Focus on GitHub Actions tool versions, Terraform providers/core, Packer plugins, Dockerfiles, npm packages, and Ansible-managed image/version vars.
- [x] Risks
  Over-broad regex managers can create noisy or invalid updates, especially for local-only image names or non-dependency numeric settings.
  Workflow-specific version regexes must point to the correct datasource or Renovate PRs will be wrong.
- [x] Implementation
  Update `renovate.json` custom managers to cover missing Ansible version vars and workflow tool versions.
  Keep built-in managers enabled for npm, Dockerfile, GitHub Actions, Terraform, and Packer surfaces already expressed in standard formats.
  Add grouping/cleanup rules where they reduce PR noise without hiding important update types.
- [x] Verification
  Validate `renovate.json` as JSON.
  Re-scan the repo and confirm each intended dependency surface is either handled by a built-in Renovate manager or by an explicit custom regex manager.
