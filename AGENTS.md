# Working Rules

Rules for anyone changing this repository, including AI coding agents.

## Before changing anything

- Read [README.md](README.md), [docs/architecture.md](docs/architecture.md),
  [docs/decisions.md](docs/decisions.md) and [docs/security.md](docs/security.md).
- The architecture is frozen. Follow the accepted ADRs. If an implementation needs a different decision,
  propose a superseding ADR first; don't rewrite an accepted ADR in place and don't work around it silently.

## Rules

- This is a **public** personal proof of concept. Never commit secrets, AWS account IDs, real IP addresses
  or `*.tfvars` files; only `terraform.tfvars.example`.
- **Pin everything:** Terraform (`.terraform-version`) and providers (committed lock files), container
  images (exact version and digest), GitHub Actions (full commit SHA with the version in a comment),
  Syft and Grype versions, and npm packages (exact versions plus the lockfile).
- **Workflows:** top-level `permissions: contents: read`; `id-token: write` only on jobs that assume an
  AWS role.
- No SSH, no key pairs, no port 22, and no long-lived AWS access keys anywhere.
- Every AWS resource is tagged through the provider's `default_tags` and named with the `sssc-` prefix.
- The AWS environment is destroyed after each work session. Never present the Dependency-Track URL as a
  live demo; screenshots and CI runs are the evidence.
- Stay within the MVP scope. Ideas beyond it go into the README's "Future Improvements" section; don't
  implement them.
- Small pull requests, one change each, with the issue in the title.
- Never run `terraform apply` or `terraform destroy` against AWS without the owner's explicit go-ahead in
  the current session.
