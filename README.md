# Secure Software Supply Chain on AWS

> **Personal proof of concept.** This is a production-like personal proof of concept. It shows cloud
> infrastructure automation, secure CI/CD, SBOM generation and vulnerability management working together
> as one repeatable system. It is not client work, and it is not a highly available production deployment.
> See [Disclaimer](#disclaimer).

[![ci](https://github.com/vkorzavatykh/secure-software-supply-chain-aws/actions/workflows/ci.yml/badge.svg)](https://github.com/vkorzavatykh/secure-software-supply-chain-aws/actions/workflows/ci.yml)
[![infrastructure](https://github.com/vkorzavatykh/secure-software-supply-chain-aws/actions/workflows/infrastructure.yml/badge.svg)](https://github.com/vkorzavatykh/secure-software-supply-chain-aws/actions/workflows/infrastructure.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Overview

Terraform provisions a small AWS environment that runs [OWASP Dependency-Track](https://dependencytrack.org/)
on EC2 (Docker) with RDS PostgreSQL behind an HTTPS Application Load Balancer. A small TypeScript demo API
lives in the same repository. Its only job is to provide a realistic dependency tree.

On every change, GitHub Actions:

1. tests and builds the demo API and its container image;
2. generates CycloneDX SBOMs with Syft, one for the application and one for the image;
3. scans them with Grype and **blocks the change if the application has a Critical vulnerability**;
4. uploads the SBOMs to Dependency-Track, which applies a second policy gate and keeps re-analysing them
   as new vulnerabilities are published.

GitHub Actions reaches AWS through OIDC, so no AWS access keys exist anywhere. There is no SSH:
administration goes through AWS Systems Manager Session Manager.

## Why This Project

A dependency that is clean on the day it's merged can be vulnerable next month without any code change.
Catching that takes two things that are often built separately, or not at all:

- a **fast gate** in the pipeline that answers *"is this change safe to merge right now?"*, and
- a **system of record** that keeps every SBOM and answers *"which of our components are affected by a
  vulnerability published since we shipped?"*

Both are only as trustworthy as the environment around them. That means reproducible infrastructure, CI
identities without long-lived secrets, no public management ports, and secrets that never reach Git or
Terraform state. This repository builds the whole path at the smallest scope that still shows each of
those decisions, and documents why each one was made.

## Architecture

```text
                          Developer ── push / PR ──► GitHub
                                                       │
                                                       ▼
               ┌─────────────────────────── GitHub Actions ───────────────────────────┐
               │  app pipeline                          infrastructure pipeline       │
               │  test → build → SBOM → scan → gate     fmt → validate → plan → apply │
               └──────────┬───────────────────────────────────────────────┬───────────┘
                          │ HTTPS + Dependency-Track API key              │ OIDC, short-lived
                          │                                               │ credentials
 ┌────────────────────────┼─────────── AWS · eu-central-1 ────────────────┼─────────────┐
 │                        ▼                                               ▼             │
 │  public         ┌─────────────┐                                    AWS APIs          │
 │  subnets        │     ALB     │◄── Internet, HTTPS only                              │
 │                 └──────┬──────┘                                                      │
 │                        │ 8080 / 8081                                                 │
 │  private app    ┌──────▼──────────────┐                                              │
 │  subnets        │ EC2                 │◄── SSM Session Manager (no SSH)              │
 │                 │ Dependency-Track    │──► NAT ──► vulnerability feeds, images       │
 │                 └──────┬──────────────┘                                              │
 │                        │ 5432, TLS                                                   │
 │  private data   ┌──────▼──────────────┐                                              │
 │  subnets        │ RDS PostgreSQL      │   no route to the internet                   │
 │                 └─────────────────────┘                                              │
 └──────────────────────────────────────────────────────────────────────────────────────┘
```

- Only the load balancer is public. The instance has no public IP, and the database subnets have no route
  to the internet.
- The instance holds no essential state of its own. Projects, findings and triage decisions live in RDS,
  and the Dependency-Track encryption key lives in Secrets Manager. The instance can be replaced at any
  time.
- The load balancer forwards nothing until the instance has replaced Dependency-Track's default admin
  credentials and verified that they no longer work ([ADR-020](docs/decisions.md#adr-020--explicit-startup-barrier-supersedes-adr-012)).

Details: [docs/architecture.md](docs/architecture.md) (network, Security Groups, routing, compute, data)
and [docs/security.md](docs/security.md) (trust boundaries, identities, secrets, pipeline, gate policy).

## Technology Stack

| Area | Choice |
|------|--------|
| Cloud | AWS `eu-central-1`: VPC, EC2, RDS for PostgreSQL, Application Load Balancer, IAM, Systems Manager, Secrets Manager, CloudWatch, Route 53, ACM |
| Infrastructure as Code | Terraform, with reusable modules and S3 state with native locking |
| CI/CD | GitHub Actions; GitHub OIDC → AWS IAM |
| Software composition analysis | OWASP Dependency-Track |
| SBOM | CycloneDX, generated by Syft |
| CI vulnerability scanner | Grype |
| Runtime | Docker Compose on Amazon Linux 2023 |
| Demo application | Node.js 24 LTS, TypeScript, Express |

## Infrastructure

Two Terraform stacks with different lifecycles:

| Stack | Applied | Contains |
|-------|---------|----------|
| `infrastructure/bootstrap` | Once, from a workstation | State bucket, GitHub OIDC provider, CI roles, Route 53 zone, ACM certificate |
| `infrastructure/environments/poc` | Per work session, from CI | Network, database, compute and load balancer, composed from `infrastructure/modules/` |

Key controls, all checkable in the Terraform code:

- **Network:** one VPC across two Availability Zones, with public, private-app and private-data subnets.
  Security Groups reference each other instead of CIDR ranges, and no rule opens port 22.
- **Compute:** IMDSv2 required, no key pair, no public IP, encrypted root volume. Any change to the
  bootstrap replaces the instance, so it is never patched by hand.
- **Data:** RDS is not publicly accessible, storage is encrypted, TLS is enforced, and the master password
  is managed by RDS in Secrets Manager. Dependency-Track connects as its own least-privilege user.
- **Identity:** each CI role trusts only this repository and one event, branch or environment.

## Security Pipeline

```text
Pull request / push
  │
  ├─ test → build                     lint, typecheck, unit tests, container image
  ├─ SBOM                             Syft → CycloneDX (application, and image with OS packages)
  ├─ scan + gate                      Grype: Critical in the application → FAIL
  ├─ upload                           SBOM → Dependency-Track (only while the environment is running)
  └─ policy gate                      unsuppressed FAIL policy violation → FAIL
```

The Grype gate always runs and needs nothing outside the CI run. The Dependency-Track stage runs only while
the AWS environment is up, and then it fails closed: if the server can't be reached, the job fails
([ADR-015](docs/decisions.md#adr-015--dependency-track-stage-only-while-the-environment-is-up)).

## SBOM Workflow

```text
                 demo API (package-lock.json)        container image
                              │                            │
                             Syft                         Syft
                              ▼                            ▼
                   sbom.cdx.json (gating)        sbom-image.cdx.json (report-only)
                      │              │                     │
                    Grype     Dependency-Track ◄───────────┘
                      │              │
                      └──── gate ────┘
```

The **same SBOM file** is scanned by Grype and uploaded to Dependency-Track, so both signals come from one
component inventory. The two tools have different jobs
([ADR-006](docs/decisions.md#adr-006--dependency-track-and-a-ci-scanner-with-different-roles)):

| | Grype in CI | Dependency-Track |
|---|---|---|
| Answers | Is **this change** safe to merge right now? | Which components are affected by vulnerabilities published **since** they shipped? |
| Runs | On every PR and push, in seconds | Continuously, on every stored SBOM |
| Depends on | Nothing outside the CI run | A running server |

The image SBOM covers OS packages too. It is scanned and tracked but doesn't block yet; blocking on fixable
Critical image findings is the documented next step
([ADR-023](docs/decisions.md#adr-023--phased-sbom-coverage-supersedes-adr-016)).

## CI/CD

| Workflow | Trigger | Does |
|----------|---------|------|
| `ci.yml` | PR, push to `main` (application and security paths) | Test and build, then calls `security.yml` |
| `security.yml` | Called by `ci.yml`; weekly schedule on `main` | SBOMs, Grype gate, Dependency-Track upload and policy gate |
| `infrastructure.yml` | PR, push to `main` (infrastructure paths); manual `apply` / `destroy` | `fmt`, `validate`, offline `terraform test`, `tflint`, `plan`; two-phase apply after approval |

Tests run on every change without an AWS account: unit and HTTP tests for the API (Vitest, coverage
thresholds), and `terraform test` suites that check the security properties above, from the CI roles' trust
policies to the startup barrier ([infrastructure/README.md](infrastructure/README.md#test-locally-no-aws-account-needed)).
Every AWS-dependent step switches itself off when its repository variable is missing, so CI stays green
while the environment is torn down.

Every workflow starts from `permissions: contents: read`. Only jobs that assume an AWS role get
`id-token: write`. Third-party actions are pinned to a full commit SHA, and Dependabot keeps those pins,
npm packages, Terraform providers and base images up to date
([ADR-017](docs/decisions.md#adr-017--hardening-the-pipelines-own-supply-chain)).

## Deployment

The environment follows one rule: **run, test, capture evidence, destroy.** It exists only during
*work sessions*: the time during which the live environment is needed, to try the demo, debug or capture
evidence. A session starts with `apply` and ends with `destroy`, it can last hours or days, and the
[runbook](docs/runbook.md#2-work-session-routine) includes a leftover check so that nothing billable
remains afterwards. Nothing stays online just to serve as a demo.

> **This is how the proof of concept is demonstrated, not how a production system runs.** Every destroy
> deletes all Dependency-Track data. A production Dependency-Track runs permanently, keeps re-analysing
> stored SBOMs, and its findings and triage decisions are backed up, not discarded.

1. **Once:** apply the bootstrap stack from a workstation and delegate the `dtrack` subdomain to its Route
   53 zone.
2. **Per session:** start the `infrastructure` workflow with `action=apply` and approve the `poc`
   environment. The workflow applies with the load balancer closed, waits until the instance reports that
   bootstrap is done, and then opens it.
3. **End of session:** run the workflow with `action=destroy`.

Prerequisites, commands and the teardown checklist are in [docs/runbook.md](docs/runbook.md).

Approximate cost while the environment is running (on-demand, `eu-central-1`): EC2 `t3.large`, RDS
`db.t4g.micro`, one ALB, one NAT Gateway and public IPv4 addresses come to about **USD 0.21 per hour**. The
bootstrap stack costs about USD 0.50 per month, almost all of it for the hosted zone.

## Security Gates

| Severity | Grype in CI | Dependency-Track policy | Pipeline |
|----------|-------------|-------------------------|----------|
| Critical | `--fail-on critical` | violation state **FAIL** | **Blocked** |
| High | reported | violation state **WARN** | Passes, with a warning in the job summary |
| Medium / Low | reported | — | Passes |

Exceptions need a written reason and go through a pull request: a Grype ignore rule with the CVE, reason,
owner and review date, and a Dependency-Track suppression with an analysis justification
([ADR-014](docs/decisions.md#adr-014--security-gate-policy)).

## Architecture Decisions

Every significant choice is recorded as an ADR in [docs/decisions.md](docs/decisions.md). The most
important ones:

| ADR | Decision |
|-----|----------|
| [001](docs/decisions.md#adr-001--terraform-for-infrastructure-as-code) | Terraform for Infrastructure as Code |
| [002](docs/decisions.md#adr-002--ec2--docker-compose-for-dependency-track) | One EC2 instance with Docker Compose, not ECS or EKS |
| [003](docs/decisions.md#adr-003--rds-postgresql) | RDS PostgreSQL, not a database on the instance |
| [004](docs/decisions.md#adr-004--ssm-session-manager-instead-of-ssh) | SSM Session Manager instead of SSH |
| [005](docs/decisions.md#adr-005--github-actions-oidc) | GitHub Actions OIDC instead of long-lived AWS keys |
| [006](docs/decisions.md#adr-006--dependency-track-and-a-ci-scanner-with-different-roles) | Dependency-Track **and** a CI scanner, with different roles |
| [014](docs/decisions.md#adr-014--security-gate-policy) | Gate policy: Critical blocks, High warns |
| [019](docs/decisions.md#adr-019--trust-boundaries-and-access-model) | Trust boundaries and access model |
| [020](docs/decisions.md#adr-020--explicit-startup-barrier-supersedes-adr-012) | No public forwarding until the default credentials are replaced and verified |

## Repository Structure

```text
.
├── app/                         demo API: src/, tests/, multi-stage Dockerfile
├── infrastructure/
│   ├── bootstrap/               one-time stack: state bucket, OIDC, CI roles, DNS zone, certificate
│   ├── modules/                 network, database, compute, edge (each with offline tests)
│   └── environments/poc/        the per-session environment: modules, user_data, alarms
├── deployment/user-data/        instance bootstrap scripts, rendered into cloud-init
├── security/scripts/            pipeline scripts (scan summary; Dependency-Track upload and gate next)
├── .github/
│   ├── workflows/               ci, security, infrastructure
│   └── dependabot.yml           npm, base images, action pins, Terraform providers
├── .grype.yaml, .syft.yaml      scanner configuration shared by CI and local runs
└── docs/                        architecture, decisions, security model, runbook
```

## Demo

There is no live demo link. The environment is destroyed after each work session, and a link that is
usually offline would help nobody. Evidence from real runs is added here as it is captured: the
infrastructure, the Dependency-Track project view, a passing pipeline, and a pull request in which a
vulnerable dependency fails both gates and the upgrade makes them pass.

## Limitations

- **Single instance, single AZ.** One EC2 instance, a single-AZ RDS instance and one NAT Gateway. There
  is no automatic recovery or scaling.
- **Ephemeral by design, not a production operating model.** The environment exists only during work
  sessions, and each destroy deletes Dependency-Track's projects, findings and triage decisions.
  Dependency-Track re-analyses stored SBOMs only while it is up. Between sessions, the weekly Grype scan
  and Dependabot cover new vulnerabilities. A production deployment runs permanently and protects its data.
- **Public evidence.** SBOMs and scan reports are workflow artifacts of a public repository. That's fine
  for a demo app. For a real product they are sensitive, because they show an attacker what to target.
- **Scoped, not minimal, CI permissions.** The apply role is narrowed from what Terraform actually calls,
  but it still manages several AWS services.
- **Image findings don't block yet.** See [ADR-023](docs/decisions.md#adr-023--phased-sbom-coverage-supersedes-adr-016).

## Future Improvements

What a production version would add, deliberately left out of this proof of concept:

- An Auto Scaling group or ECS service across AZs, Multi-AZ RDS and a NAT Gateway per AZ.
- VPC interface endpoints for SSM, Secrets Manager and CloudWatch Logs.
- WAF, IP allow-lists or private access, and SSO for the Dependency-Track UI.
- Automated rotation of the application database user.
- Blocking on fixable Critical findings in the container image, based on a base-image policy.
- Signed images and SBOM attestations (Sigstore/cosign) and SLSA provenance.
- IaC scanning (Checkov or Trivy) on pull requests.
- Permission boundaries and per-module CI roles.
- Dashboards, ALB access logs and central log retention.

## Project Status

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Architecture and decisions | Done |
| 2 | Repository skeleton; local Dependency-Track spike | Skeleton done; spike next (it also picks Dependency-Track v4.14 or v5, see [architecture §6](docs/architecture.md#6-compute-the-ec2-instance)) |
| 3 | AWS infrastructure in Terraform | Written, validated and tested offline; not yet applied to AWS |
| 4 | Dependency-Track automation on the instance | Host preparation done (Docker, Compose, logging); Dependency-Track steps follow the spike |
| 5 | Demo API and security pipeline | API, tests, SBOMs and the Grype gate done; Dependency-Track upload and policy gate follow the spike |
| 6 | Security gate demo (fail → fix → pass) | Grype side verified locally; the demo pull request comes with Phase 5 |
| 7 | Evidence, diagram and final documentation | Not started |

## About the Author

Built by Volodymyr Korzavatykh, co-founder of [Frontward Solutions](https://frontward-solutions.com), as a
Frontward Solutions proof of concept.

## Disclaimer

This repository is a production-like personal proof of concept. It was built to demonstrate cloud
infrastructure automation, secure CI/CD, SBOM generation and vulnerability management. It does not
represent client work, and it is not a complete, highly available enterprise production deployment.

## License

[MIT](LICENSE)
