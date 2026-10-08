# Architecture Decision Log

> **Status values:** `Accepted (plan)` = fixed by the original project scope · `Accepted` = agreed in the Phase 1
> review · `Proposed` = recommended, not yet agreed · `Open` = needs input · `Superseded`.
>
> **Architecture frozen on 2026-10-06** (Phase 1 review). A second review the same day found four
> incorrect assumptions, corrected through ADR-020 to ADR-023 under the rule below. From here on, an accepted ADR changes only when
> implementation proves it wrong. In that case, add a new ADR that supersedes it and mark the old one
> `Superseded`; don't rewrite it in place.

## Summary

| ADR | Decision | Status |
|-----|----------|--------|
| 001 | Terraform for Infrastructure as Code | Accepted (plan) |
| 002 | Dependency-Track on a single EC2 instance with Docker Compose, not ECS/EKS | Accepted (plan) |
| 003 | RDS PostgreSQL instead of a database on the instance | Accepted (plan), **amended by 021** |
| 004 | SSM Session Manager instead of SSH | Accepted (plan) |
| 005 | GitHub Actions OIDC instead of long-lived AWS keys | Accepted (plan) |
| 006 | Dependency-Track **and** a CI scanner, with different roles | Accepted (plan) |
| 007 | Production-like topology with one NAT Gateway (cost/availability compromise) | Accepted |
| 008 | S3 state with native locking; separate bootstrap stack | Accepted |
| 009 | Runtime configuration delivered through Terraform-rendered user_data | Accepted |
| 010 | RDS-managed master password in Secrets Manager | Accepted, **amended by 022** |
| 011 | HTTPS on `dtrack.frontward-solutions.com`, a delegated subdomain; zone and certificate in the bootstrap stack | Accepted |
| 012 | First-run Dependency-Track configuration automated on the instance | **Superseded by 020** |
| 013 | Grype as the CI scanner (not Trivy) | Accepted |
| 014 | Security gate policy: Critical blocks, High warns | Accepted |
| 015 | Dependency-Track stage runs only while the environment is up | Accepted |
| 016 | MVP SBOM scope: application dependencies; container image later | **Superseded by 023** |
| 017 | GitHub Actions pinned by commit SHA; least-privilege workflow permissions | Accepted |
| 018 | The demo API is built and scanned, not deployed | Accepted |
| 019 | Trust boundaries and access model | Accepted, point 3 **amended by 022** |
| 020 | Explicit startup barrier: no public forwarding until bootstrap succeeds | Accepted, point 1 **amended by 024** |
| 021 | Dependency-Track secret key is essential state, kept in Secrets Manager | Accepted, **amended by 024** |
| 022 | Dedicated application database user; master credentials for bootstrap only | Accepted |
| 023 | Phased SBOM coverage: application blocking, container image report-only | Accepted |
| 024 | Dependency-Track v5: key encryption key from the bootstrap, no NVD API key, OSV enabled, `t3.medium` | Accepted |

---

### ADR-001 — Terraform for Infrastructure as Code

- **Context.** The environment must be reproducible, reviewable and destroyable in one command.
- **Decision.** Terraform with reusable modules (`network`, `database`, `compute`, `edge`) composed per
  environment.
- **Why.** The plan output can be reviewed in a pull request before anything changes. Terraform is widely
  used across clouds, and modules and state are well understood by most reviewers.
- **Alternatives.** AWS CDK (the author has used it commercially; equally valid on AWS); CloudFormation
  (more verbose); Pulumi.
- **Consequences.** State must be stored and protected (see ADR-008).

### ADR-002 — EC2 + Docker Compose for Dependency-Track

- **Context.** Dependency-Track is a stateful Java application plus a static frontend. The goal is to show
  the full path from bare infrastructure to a running service.
- **Decision.** One EC2 instance runs both containers through Docker Compose under systemd.
- **Why.** It makes OS bootstrap, runtime configuration and health verification visible. It's the
  cheapest option that still separates compute from data, and it avoids a cluster for two containers.
- **Alternatives.** ECS on Fargate (a sensible production choice: no hosts, rolling deploys); EKS
  (overkill here).
- **Consequences.** No automatic recovery or scaling. Listed as a production improvement.

### ADR-003 — RDS PostgreSQL

> **Amended by ADR-021:** the instance does hold one piece of essential state, the Dependency-Track
> secret key. RDS alone doesn't preserve everything.

- **Decision.** Dependency-Track uses an external RDS PostgreSQL instance; nothing persistent lives on the
  instance.
- **Why.** It separates the compute and data lifecycles, gives managed backups and restore, and lets the
  instance be replaced at will.
- **Alternatives.** PostgreSQL in a container on the same host (couples data to an instance disk); the
  embedded database (not suitable beyond evaluation).

### ADR-004 — SSM Session Manager instead of SSH

- **Decision.** No key pair, no port 22, no bastion host. Administration happens through Session Manager
  (shell and port forwarding).
- **Why.** No inbound management port and no SSH keys to rotate. Access is controlled by IAM and can be
  logged.
- **Consequences.** The instance needs the SSM agent (included in AL2023), the
  `AmazonSSMManagedInstanceCore` policy and outbound HTTPS.

### ADR-005 — GitHub Actions OIDC

- **Decision.** Workflows exchange a GitHub OIDC token for short-lived AWS credentials through
  `AssumeRoleWithWebIdentity`. Each role's trust policy is limited to this repository **and** to a specific
  branch, PR event or environment (`sub` claim).
- **Why.** No long-lived AWS keys exist anywhere, so there is nothing to leak or rotate. Who may assume a
  role is decided by AWS IAM, not by whoever can read a GitHub secret.
- **Consequences.** A one-time bootstrap stack creates the OIDC provider and roles, so CI can't create its
  own identity (ADR-008).

### ADR-006 — Dependency-Track and a CI scanner, with different roles

- **Decision.** Both tools run, for different purposes.

  | | CI scanner (Grype) | Dependency-Track |
  |---|---|---|
  | When | Every PR and push, in seconds | Continuously, after the SBOM is stored |
  | Answers | "Is **this change** safe to merge right now?" | "Which of our components are affected by vulnerabilities published **since** we shipped?" |
  | Depends on | Nothing outside the CI run | A running server |
  | Strength | Fast feedback, works offline from the platform | Portfolio view, re-analysis as new CVEs appear, policy management, audit trail of triage decisions |

- **Why.** A dependency that is clean today can be vulnerable tomorrow without any code change. Only a
  system that keeps the SBOM and re-analyses it catches that. A PR gate shouldn't depend on a server being
  up.

### ADR-007 — Production-like topology with one NAT Gateway

- **Context.** The network layout is part of what this project demonstrates: only the load balancer is
  public, while compute and data stay private. The instance in a private subnet still needs outbound HTTPS
  (vulnerability feeds, image pulls, OS packages, SSM).
- **Decision.** This is intentionally a production-like network topology. The single NAT Gateway is a
  cost/availability compromise for the POC, and the environment is ephemeral. One NAT Gateway in AZ a
  serves both private app subnets.
- **Cost.** About USD 38/month *if left running*. Because the environment exists only during work sessions
  ([runbook §2](runbook.md#2-work-session-routine)), the real cost is about USD 1.25 per full day of use. The cost is a deliberate trade-off, not
  an oversight.
- **Alternatives.** (a) Instance in a public subnet, with Security Groups allowing traffic only from the
  ALB: cheapest, but it removes the public/private boundary the project is meant to show. (b) NAT instance
  (fck-nat): cheap, but more to operate. (c) VPC interface endpoints only: Dependency-Track needs the public
  internet anyway.
- **Consequences.** A single NAT is a single point of failure for egress, which is accepted for a POC.
  Production would use one NAT Gateway per AZ ([architecture §11](architecture.md#11-what-a-production-version-would-change)).

### ADR-008 — S3 state with native locking; separate bootstrap stack

- **Decision.** The `bootstrap` stack (state bucket, OIDC provider, CI roles) is applied once from a
  workstation and kept permanently. The `poc` environment uses an S3 backend with `use_lockfile = true`
  (Terraform ≥ 1.10), with no DynamoDB lock table.
- **Why.** CI can't create the identity it uses to authenticate. Keeping the long-lived and short-lived
  parts in separate stacks makes `terraform destroy` on the environment safe.
- **Consequences.** One documented manual step ([runbook §1](runbook.md#1-one-time-bootstrap-workstation-admin-sso-credentials)). The state bucket is versioned, encrypted and
  blocks public access, because state can contain sensitive values.

### ADR-009 — Runtime configuration through Terraform-rendered user_data

- **Decision.** `deployment/docker-compose.yml` and the bootstrap scripts are rendered with `templatefile`
  into cloud-init user_data, with `user_data_replace_on_change = true`.
- **Why.** Every running configuration traces back to a commit, there are no hand-edits on the host, and
  any change replaces the instance, which is safe because of ADR-003.
- **Watch out.** user_data is limited to 16 KB. If the scripts and policies grow past it, use
  `cloudinit_config` with gzip, or move the artefacts to a private S3 bucket fetched at boot.
- **Alternatives.** Ansible over SSM (an extra tool), a baked AMI with Packer (slower iteration), an S3
  artefact bucket.

### ADR-010 — RDS-managed master password

> **Amended by ADR-022:** RDS rotates this password every 7 days by default, so Dependency-Track no
> longer connects with it. The master user is used only by the bootstrap.

- **Decision.** `manage_master_user_password = true`. RDS creates and stores the password in Secrets
  Manager. The instance role can read **only that secret**.
- **Why.** The password never appears in Terraform code, variables, plan output or state.
- **Production note.** Use a dedicated least-privilege database user for Dependency-Track, and rotate it.

### ADR-011 — HTTPS on a delegated subdomain of an existing domain

- **Context.** The ALB must serve HTTPS with an ACM certificate. The environment is destroyed and
  recreated every session, so the ALB's DNS name changes on every apply.
- **Decision.** Use `dtrack.frontward-solutions.com`, a subdomain of the author's company domain, and don't
  buy a new domain. Delegate that subdomain to a Route 53 hosted zone (one-time NS records at the parent
  domain's DNS provider). The **hosted zone, the ACM certificate and a CAA record allowing `amazon.com` live
  in the bootstrap stack**, which stays for the whole project. The ephemeral environment only creates the
  ALB alias record at the zone apex.
- **Why.** A subdomain of an existing domain looks more professional than a throwaway domain and doesn't
  create another asset to renew every year. Delegation lets Terraform update the record on every apply. A
  hand-managed CNAME would break each session. Keeping the certificate permanent avoids waiting for
  validation every session.
- **Alternatives.** A new cheap domain in Route 53 (works, but adds an extra asset). Manual CNAMEs at the
  parent's DNS provider (break on every recreate). HTTP only (rejected).
- **Consequences.** About USD 0.50/month for the hosted zone. The CAA record in the delegated zone means
  certificate issuance doesn't depend on the parent domain's CAA policy. The alias record is destroyed with
  the environment, so nothing dangles between sessions. **At the end of the project, the NS delegation at
  the parent domain must be removed before the hosted zone is deleted**, because a delegation to a deleted
  zone is a known subdomain-takeover pattern ([runbook §6](runbook.md#end-of-project-final-teardown)).

### ADR-012 — First-run configuration automated on the instance

> **Superseded by ADR-020.** The protection argument below is wrong: an ALB routes to a new target after
> its first passing health check, and fails open when all targets are unhealthy.

- **Context.** A new Dependency-Track instance starts with a default administrator password. The CI
  pipeline needs an API key, and the security policies must exist before the first gate.
- **Decision.** The bootstrap script talks to the apiserver on `localhost`. As soon as it is ready, the
  script changes the admin password (new value from Secrets Manager), creates a `ci` team with only the
  permissions needed for upload and reading results, stores the team's API key as an SSM SecureString, and
  applies the policies from `security/policies/`.
- **Why.** No manual clicks between `terraform apply` and the first SBOM upload. The default credentials
  are replaced before the ALB marks the target healthy, because the health-check threshold adds tens of
  seconds of delay.
- **Residual risk.** A short window if the health check passes earlier than expected. For the first deploy,
  `allowed_ingress_cidrs` can be set to your own IP.
- **Fallback.** If the API calls prove fragile on the pinned version, use a documented manual procedure
  ([runbook §3](runbook.md#3-first-run-configuration)) and record it as a limitation.

### ADR-013 — Grype as the CI scanner

- **Decision.** Grype scans the **same CycloneDX SBOM** that is uploaded to Dependency-Track.
- **Why.** It comes from the same project family as Syft, so both signals are based on the identical
  component inventory, with one SBOM as the single source of truth. It's simple to configure
  (`--fail-on`, ignore rules with reasons).
- **Alternative.** Trivy covers more ground (IaC, secrets, misconfigurations). It's a candidate for a
  separate IaC-scanning step later; it isn't needed for SCA.

### ADR-014 — Security gate policy

- **Decision (v1).**

  | Severity | Grype in CI | Dependency-Track policy | Pipeline |
  |----------|-------------|-------------------------|----------|
  | Critical | `--fail-on critical` | violation state **FAIL** | **Blocked** |
  | High | reported | violation state **WARN** | Passes with a warning in the job summary |
  | Medium / Low | reported | INFO / none | Passes |

- **Exceptions.** Only with a written reason. Grype uses an ignore rule in `.grype.yaml` with a comment
  (CVE, reason, owner, review date). Dependency-Track uses a suppression with an analysis justification. The
  exception is visible in Git history and in the Dependency-Track audit trail.
- **Why.** It is simple, explainable and stable enough to keep `main` green with healthy dependencies.
  Blocking High is a reasonable production tightening, listed as such.
- **Alternatives.** Block High as well; block only when a fixed version exists (`--only-fixed`). Both are
  valid; the choice depends on how much noise the team accepts.

### ADR-015 — Dependency-Track stage only while the environment is up

- **Context.** The AWS environment is destroyed between work sessions for cost reasons ([runbook §2](runbook.md#2-work-session-routine)). A required
  Dependency-Track step would turn CI red most of the time.
- **Decision.** The Grype gate is **always** required. The Dependency-Track upload and policy gate run only
  when the repository variable `DTRACK_URL` is set. When it is set, the gate fails closed: an unreachable
  server fails the job.
- **Consequence.** The README states plainly that continuous monitoring only happens while the environment
  runs. In production, Dependency-Track runs permanently.

### ADR-016 — MVP SBOM scope

> **Superseded by ADR-023.** Leaving the image out because it might fail the gate optimised for a green
> demo, not for coverage.

- **Decision.** The MVP SBOM covers the application's dependency tree (Syft over `app/` with the lockfile).
  An SBOM of the built container image, including OS packages, is a stretch goal and is uploaded as a
  separate Dependency-Track project.
- **Why.** Base-image OS vulnerabilities, often without a fix available, would make the gate fail for
  reasons unrelated to the application change being demonstrated.

### ADR-017 — Hardening the pipeline's own supply chain

- **Decision.** Third-party actions are pinned to a **full commit SHA** (with the version in a comment);
  Dependabot updates them. Every workflow sets `permissions: contents: read` by default. `id-token: write`
  is granted only to jobs that assume an AWS role.
- **Why.** Tags can be moved. In the March 2025 `tj-actions/changed-files` incident, a repointed tag ran
  malicious code that exposed CI secrets in many repositories. A supply-chain project should protect its own
  pipeline.

### ADR-018 — The demo API is not deployed

- **Decision.** The demo API is tested, built (including its Docker image), scanned and tracked, but not
  deployed to AWS.
- **Why.** Its only job is to provide a realistic dependency tree. Deploying it would add an ECR repository,
  a deployment and a second target without strengthening the supply-chain story.

### ADR-019 — Trust boundaries and access model

> **Point 3 amended by ADR-022:** Dependency-Track connects as the dedicated `dtrack` user; the
> RDS-managed master secret is used only by the bootstrap.

- **Context.** A reviewer judges a security project by who can reach and change what, not by its tool
  list. The answers should fit on one page and be checkable against the Terraform code.
- **Decision.** The access model is fixed by four answers. The diagram and details are in
  [security §2](security.md#2-trust-boundaries).
  1. **Publicly reachable:** only the ALB on 443 (80 redirects). The instance has no public IP; RDS has no
     internet route.
  2. **Dependency-Track administration:** only the single `admin` account (password in Secrets Manager),
     plus shell access through SSM for the AWS account owner. No CI identity has admin rights.
  3. **PostgreSQL access:** only from the Dependency-Track instance (Security Group reference + RDS-managed
     secret). No CI identity can read the database secret.
  4. **SBOM upload and results:** only through the `ci` team API key, which only the `sssc-gha-dtrack` OIDC
     role and the owner can read. SBOMs and scan reports of the demo app are public on GitHub by design.
- **Why.** It is a one-page model a reviewer can check, and it turns the scattered controls (subnets,
  Security Groups, roles, keys) into a single statement.
- **Consequences.** Any change that adds a publicly reachable endpoint, a new identity with Dependency-Track
  admin or database access, or a new reader of the CI key needs a new ADR.

### ADR-020 — Explicit startup barrier (supersedes ADR-012)

> **Point 1 amended by ADR-024:** Dependency-Track v5 has no NVD API key setting. First-run enables the
> OSV data source instead, and its check of the default login reads the response body, not only the status.

- **Context.** Every session starts with a fresh database, so Dependency-Track's default admin credentials
  exist at every first start. ADR-012 relied on the health-check threshold to delay public exposure. That is
  wrong: an ALB starts routing to a newly registered target after its **first** passing health check,
  whatever the threshold. If all targets are unhealthy, it fails open and routes to all of them
  ([AWS docs](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html)).
  A health-check path that only turns green after bootstrap doesn't help either, because of the fail-open
  behaviour.
- **Decision.**
  1. First-run configuration stays automated on the instance against `localhost`: admin password, `ci`
     team and key, policies, NVD API key setting.
  2. **Public forwarding stays disabled until bootstrap succeeds.** A Terraform variable `dtrack_public`
     (default `false`) controls the HTTPS listener. While it's `false`, the listener answers with a fixed
     `503 Starting` response and has no forward rules, so no request can reach the instance.
  3. Bootstrap writes `/sssc/dtrack/bootstrap-status = done` only after it has **verified** that a login
     with the default credentials is rejected.
  4. A session starts in two phases, in one approved workflow job: `apply` (`dtrack_public=false`) → wait
     for `done` → `apply` (`dtrack_public=true`).
- **Why.** The barrier lives in Terraform: it's visible in the plan, needs no extra instance permissions,
  and fails closed. If bootstrap never finishes, nothing is ever exposed.
- **Alternatives.** A host firewall rule (`DOCKER-USER` chain) until bootstrap ends: works, but hides the
  state on the host. The instance registering itself with the target groups at the end of bootstrap: needs
  ELB write permissions on the instance role. Both are possible defence-in-depth later.
- **Consequences.** Session start takes one extra apply (about a minute). Replacing the instance mid-session
  keeps the existing database, so no default credentials exist and the listener can stay public.

### ADR-021 — Dependency-Track secret key is essential state (amends ADR-003)

> **Amended by ADR-024:** the decision holds (the key is essential state, kept in Secrets Manager, with the
> lifetime of the database), but the mechanism below is v4's. In v5 the key is a key encryption key that the
> bootstrap generates *before* the first start and passes as a file; `secret.key`, `ALPINE_SECRET_KEY_PATH`
> and the capture step no longer apply, and nothing else in the data directory is essential.

- **Context.** Dependency-Track encrypts confidential values (for example, access tokens for external
  services) with AES-256 before storing them in the database. It uses a secret key that it generates on
  first start under `<data dir>/keys/secret.key`
  ([Dependency-Track configuration](https://docs.dependencytrack.org/getting-started/configuration/)).
  In this project, the NVD API key setting is such a value. Replacing the instance without the key would
  leave it unreadable.
- **Decision.** The data directory is classified as follows.

  | Item | Class | Handling |
  |------|-------|----------|
  | Secret key (`keys/secret.key`) | **Essential** | Kept in Secrets Manager `sssc/dtrack/secret-key` (container created by Terraform, value written by the instance after first start). Restored to a `0600` file before Dependency-Track starts on later boots; `ALPINE_SECRET_KEY_PATH` (supported since 4.7) points to it |
  | JWT signing keys | Disposable | Losing them only logs users out |
  | Vulnerability mirror data, search indexes, logs | Disposable cache | Rebuilt on start (slow, but nothing is lost) |

  The key has the same lifetime as the database: both are destroyed together with the environment.
- **Why.** "Stateless compute" is only true once every piece of essential state has a home outside the
  instance.
- **Consequences.** The instance role can read and write this one secret. The replacement test (P4-05)
  must prove that an encrypted setting still works after replacement. The local spike checks the key file
  format and the exact classification of the other items for the pinned version.

### ADR-022 — Dedicated application database user (amends ADR-010)

- **Context.** RDS rotates a managed master password every 7 days by default, and applications must fetch
  the current value
  ([AWS docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html)).
  Reading it once into `.env` would break new database connections after a rotation. Short-lived
  environments would rarely hit this, but the design shouldn't depend on luck.
- **Decision.** The master user (RDS-managed, rotation left on) is used **only by the bootstrap**, which
  reads it at the moment of use. With it, the bootstrap creates (idempotently) role `dtrack` and database
  `dtrack` owned by that role. The `dtrack` password is generated on the instance and stored in
  `sssc/dtrack/db-app`. Its lifecycle is explicit: it lives as long as the environment, and rotation is a
  runbook procedure (new password → `ALTER ROLE` → update secret → restart Dependency-Track). Dependency-Track
  connects as `dtrack`, over TLS.
- **Why.** The application no longer depends on the master rotation schedule, and it gets least privilege:
  `dtrack` isn't `rds_superuser`. This also delivers ADR-010's former "production note".
- **Alternatives.** Keep the master user and add a refresh hook (rotation event → SSM Run Command →
  re-read the secret and restart): more moving parts. IAM database authentication: tokens expire after
  15 minutes and Dependency-Track's JDBC configuration expects a static password. Disabling rotation: hides
  the problem.
- **Consequences.** The bootstrap runs one-off `psql` commands through the official `postgres` container
  image, so no host package is needed. Automated rotation of the application user is a production
  improvement.

### ADR-023 — Phased SBOM coverage (supersedes ADR-016)

- **Context.** ADR-016 left the container image out of the MVP because base-image findings might fail the
  gate. That optimises for a green demo. The real question is how blocking scope should grow, not whether
  findings are looked at.
- **Decision.**
  - **Phase 1 (MVP):** every run produces two SBOMs.
    - **Application SBOM:** blocking per ADR-014.
    - **Image SBOM** of the built container, OS packages included: scanned **report-only** (Grype without
      `--fail-on`, results in the job summary) and uploaded to Dependency-Track as a separate project,
      `sssc-demo-api-image`. The Dependency-Track gate evaluates only the application project.
  - **Phase 2 (documented, not implemented):** block on *fixable* Critical findings in the image, once a
    base-image policy exists (minimal base image, rebuild cadence, exceptions for unfixed CVEs).
- **Why.** Full visibility now, with the blocking scope growing deliberately and documented.
- **Consequences.** One more SBOM and scan step (seconds). Image findings are visible in Dependency-Track and
  in every job summary. A minimal base image is used, which reduces noise honestly.

### ADR-024 — Dependency-Track v5 (supersedes the v4 specifics of ADR-021 and the NVD API key)

- **Context.** The design was written for Dependency-Track v4. At kickoff, v5 had been GA since June 2026, and
  v4 gets fixes only until about six months after that. The local spike ([spike/README.md](../spike/README.md))
  ran v5.1.2 against PostgreSQL in the same topology and checked every assumption of ADR-020 to ADR-022. The
  architecture holds; seven details differ.
- **Decision.**
  1. **Version.** `dependencytrack/apiserver` and `dependencytrack/frontend` 5.1.2, pinned by digest, on
     PostgreSQL 17 (v5 needs 14 or later). Configuration uses `DT_*` names; v4's `ALPINE_*` names make v5
     refuse to start.
  2. **Key encryption key (KEK).** v5 encrypts secrets with a KEK and refuses to serve when the KEK doesn't
     match the database. The bootstrap generates the KEK (`openssl rand -base64 32`) once per environment,
     **before** the first start, and stores it in `sssc/dtrack/secret-key`. On every boot it restores the KEK
     to a file that only the container can read and passes it as
     `DT_SECRET_MANAGEMENT_DATABASE_KEK=${file::/run/secrets/kek}`. The database password is passed the same
     way, so neither value appears in the container environment, a command line or a log.
  3. **Health checks use the API.** With a wrong KEK, the API port never opens, but the process stays up and
     the management endpoint `:9000/health` reports UP. The load balancer and the bootstrap's readiness wait
     therefore use `GET /api/version` on the API port, never `:9000/health`.
  4. **No NVD API key.** v5 mirrors the public NVD JSON 2.0 feed files and has no NVD API key setting. The
     parameter `/sssc/dtrack/nvd-api-key`, its permissions and its runbook step are removed.
  5. **OSV is enabled by first-run.** A fresh instance enables only NVD, which matches npm packages poorly.
     First-run enables OSV for npm and starts its first mirror.
  6. **First-run and gate details.** The default-login check reads the body (`INVALID_CREDENTIALS`): both
     before and after the password change the status is 401. The gate waits for the upload token's status
     `COMPLETED`, which covers import, analysis and policy evaluation, and reads every page of violations and
     findings (the API returns 100 items by default). CycloneDX 1.7 is accepted, so CI uses Syft's default.
  7. **Instance size.** The apiserver needs about 490 MiB with the NVD and OSV data loaded (v4 needed about
     4.5 GiB). The instance moves from `t3.large` (8 GiB) to `t3.medium` (4 GiB), which halves the EC2 cost.
- **Why.** The current major line, which stays supported after the project is published; a simpler and
  stronger bootstrap (no capture step after the first start, one secret fewer, no secret in the container
  environment); a fail-closed reaction to a wrong key instead of silently unreadable settings; and lower cost.
- **Alternatives.** Stay on v4.14 (matches the original design, but reaches end of life soon after the
  project is published). Let v5 generate a KEK keyset file and capture it after the first start, as ADR-021
  did for v4 (supports KEK rotation, but brings back the capture step and a window where the key exists only
  on the instance).
- **Consequences.** The instance holds no essential state at all: the data directory is disposable cache.
  KEK rotation isn't supported with a key passed through configuration; that is listed as a production
  improvement. Image findings differ between the tools: Grype reports the base image's unfixed Debian CVEs,
  Dependency-Track doesn't, which supports ADR-006 and ADR-023.
