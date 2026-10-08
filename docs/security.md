# Security Model, Pipeline and Security Gate

> Network controls (subnets, Security Groups) are in [architecture.md](architecture.md); the
> reasons behind each choice are in [decisions.md](decisions.md).

## 1. What we protect

1. **The delivery decision.** A change with a blocking vulnerability must not reach `main` unnoticed.
2. **The AWS account.** Only this repository's approved workflows, and the owner, can change it.
3. **Dependency-Track data.** The SBOM inventory, findings and triage decisions (the audit trail).
4. **Secrets.** Database credentials, Dependency-Track admin credentials and API keys.

## 2. Trust boundaries

The decision record for this section is ADR-019.

```text
                      Internet
                         │ 443 only (80 → redirect)
 ════════════════════════╪════════════════════════════  B2  public edge
                      [ ALB ]
                         │ 8080 / 8081, Security Group reference
 ════════════════════════╪════════════════════════════  B3  private compute
             [ EC2: Dependency-Track ] ◄── SSM Session Manager ◄── Owner (IAM)      B7
                         │ 5432, TLS, Security Group reference
 ════════════════════════╪════════════════════════════  B4  private data
                      [ RDS ]

 GitHub Actions ── OIDC (this repo + branch / PR / environment) ──► [ AWS IAM roles ]   B1
 CI job ── HTTPS + `ci` team API key ──► [ Dependency-Track API, through the ALB ]        B6
```

| Question | Answer |
|----------|--------|
| **What is publicly reachable?** | Only the ALB on 443 (80 redirects), and it forwards nothing until bootstrap has replaced and verified the default credentials (ADR-020). Behind it are the Dependency-Track UI and API, protected by login or API key. The EC2 instance has no public IP; RDS isn't publicly accessible and its subnets have no internet route. `allowed_ingress_cidrs` can narrow the ALB further. |
| **Who can administer Dependency-Track?** | Only the single `admin` account. Its password is generated on the instance and stored in Secrets Manager, readable by the AWS account owner and the instance role. The `ci` team has no admin permissions. Host-level access is through SSM only, for IAM principals allowed `ssm:StartSession` (the owner); no CI role has it. |
| **Who can access PostgreSQL?** | Network: only the `sssc-app` Security Group, that is, the Dependency-Track instance. Credentials: Dependency-Track uses the dedicated `dtrack` user (password in `sssc/dtrack/db-app`). The RDS-managed master secret is used only by the bootstrap (ADR-022). Both are readable only by the instance role and the owner. People reach the database only through an SSM port-forward via the instance. No CI role can read the secret. |
| **Who can upload or read SBOMs and vulnerability results?** | In Dependency-Track: holders of the `ci` API key (upload + read) and the admin. The key can be read from SSM only by `sssc-gha-dtrack` (this repository's `main` and PRs from its own branches, which only the owner can push) and by the owner. On GitHub: SBOMs and scan reports are workflow artifacts and job summaries of a **public** repository, so anyone can see them. That's acceptable here because the app is a demo. For a real product, SBOMs and vulnerability reports are sensitive (they show an attacker what to target) and would be kept private. |

| # | Boundary | Crossed by | Control |
|---|----------|------------|---------|
| B1 | GitHub → AWS | Workflow jobs | OIDC; role trust limited to repo + event/branch/environment; short-lived credentials |
| B2 | Internet → ALB | Browsers, CI uploads | HTTPS only (80 redirects); optional `allowed_ingress_cidrs`; Dependency-Track authentication |
| B3 | ALB → EC2 | HTTP 8080/8081 | Security Group reference; instance in a private subnet with no public IP |
| B4 | EC2 → RDS | PostgreSQL 5432 | Security Group reference; data subnet without an internet route; TLS required |
| B5 | EC2 → Internet | Vulnerability feeds, images, packages | NAT, outbound only; pinned image versions |
| B6 | CI → Dependency-Track API | SBOM upload, results read | Dedicated `ci` team API key with minimal permissions; key read from SSM at runtime |
| B7 | Administrator → EC2 | Shell, port forwarding | SSM Session Manager; IAM-controlled; no SSH, no key pair |

## 3. Identities and permissions

Repository: `vkorzavatykh/secure-software-supply-chain-aws`. All roles use `aud = sts.amazonaws.com`.

| Identity | Assumed by (trust `sub`) | Allowed to |
|----------|--------------------------|------------|
| `sssc-gha-tf-plan` | `repo:vkorzavatykh/secure-software-supply-chain-aws:pull_request` | Read infrastructure (start from `ReadOnlyAccess`, then narrow); read and write **only** the state object and its `.tflock` in the state bucket |
| `sssc-gha-tf-apply` | `repo:vkorzavatykh/secure-software-supply-chain-aws:environment:poc` | Manage the services in use (EC2, ELB, RDS, SSM, Logs, CloudWatch, SNS, Secrets Manager metadata); ACM read only; Route 53 record changes only in the project's hosted zone. IAM limited to `sssc-*` roles and instance profiles, and `iam:PassRole` only for `sssc-ec2` |
| `sssc-gha-dtrack` | `repo:vkorzavatykh/secure-software-supply-chain-aws:pull_request`, `repo:vkorzavatykh/secure-software-supply-chain-aws:ref:refs/heads/main` | `ssm:GetParameter` on `/sssc/dtrack/ci-api-key` only; `kms:Decrypt` through SSM only |
| `sssc-ec2` (instance) | `ec2.amazonaws.com` | `AmazonSSMManagedInstanceCore`; read the RDS master secret; read and write `sssc/dtrack/admin`, `sssc/dtrack/db-app` and `sssc/dtrack/secret-key`; write `/sssc/dtrack/ci-api-key` and `/sssc/dtrack/bootstrap-status`; write to its log group |
| Dependency-Track `ci` team | API key | BOM upload, project creation on upload, view portfolio, vulnerabilities and policy violations. Check the permission names against the pinned version |

**Least-privilege note.** The apply role is the hardest to narrow. Phase 3 starts with service-level
permissions plus a tight IAM section, then narrows from what Terraform actually calls (CloudTrail /
IAM Access Analyzer policy generation). Publish the final policy and describe it honestly as "scoped, not
minimal".

Fork pull requests don't receive OIDC tokens and can't assume any role. The Dependency-Track job is
skipped for them.

## 4. Secrets inventory

| Secret | Created by | Stored in | Read by | Never appears in |
|--------|------------|-----------|---------|------------------|
| RDS master password (rotated every 7 days by default) | RDS (`manage_master_user_password`) | Secrets Manager (RDS-managed) | `sssc-ec2`, **bootstrap only** (ADR-022) | Git, Terraform state, logs |
| Database application user `dtrack` | Instance bootstrap (random), once per environment | Secrets Manager `sssc/dtrack/db-app` | `sssc-ec2` (Dependency-Track's `.env`, mode 0600) | Git, Terraform state, logs |
| Dependency-Track key encryption key (protects the secrets Dependency-Track stores in the database) | Instance bootstrap (random), once per environment, before the first start (ADR-024) | Secrets Manager `sssc/dtrack/secret-key`; restored on every boot to a file mounted into the apiserver (ADR-021) | `sssc-ec2` | Git, Terraform state, logs, AMIs, container environment |
| Dependency-Track admin password | Instance bootstrap (random) | Secrets Manager `sssc/dtrack/admin` (container created by Terraform, value written by the instance) | Owner, through console or CLI | Git, Terraform state |
| Dependency-Track CI API key | Instance bootstrap | SSM SecureString `/sssc/dtrack/ci-api-key` (written by the instance, not managed by Terraform) | `sssc-gha-dtrack` (OIDC) | GitHub secrets, Git, Terraform state, logs (masked with `::add-mask::`) |
| AWS credentials for CI | **none exist** (OIDC) | — | — | — |
| Terraform state | Terraform | S3: private, encrypted, versioned | Owner, CI roles | Git |

Guardrails: GitHub push protection, a gitleaks pre-commit hook, and `.gitignore` for `*.tfvars` (only
`terraform.tfvars.example` is committed). Bootstrap scripts never echo secrets (no `set -x` around secret
handling).

The bootstrap must be **idempotent**. If the instance is replaced while RDS is kept, the admin password
already exists and must not be reset. Existing keys and policies are reused, not duplicated.

## 5. Pipeline

### Workflows

| File | Trigger | Jobs |
|------|---------|------|
| `.github/workflows/ci.yml` | Every PR (so its checks can be required on `main`); push to `main` (paths `app/**`, `security/**`) | `test-build` → calls `security.yml` |
| `.github/workflows/security.yml` | `workflow_call`; weekly `schedule` on `main` | `sbom-scan` → `dependency-track` (conditional) |
| `.github/workflows/infrastructure.yml` | Every PR; push to `main` (paths `infrastructure/**`, `deployment/**`); `workflow_dispatch` (`action = apply \| destroy`) | `validate-plan` → `apply` or `destroy` (environment `poc`) |
| `.github/dependabot.yml` | — | npm (`app/`), GitHub Actions, Terraform providers |

Every workflow sets `permissions: contents: read` at the top. Jobs that assume AWS roles add
`id-token: write`. Actions are pinned by SHA (ADR-017).

### `ci.yml` → `test-build`

`npm ci` → lint → typecheck → unit tests → `npm run build` → `docker build` (image not pushed, ADR-018).

### `security.yml` → `sbom-scan` (always required)

```text
1. Syft: app/ (with package-lock.json) → sbom.cdx.json (CycloneDX JSON)
2. Grype: sbom:sbom.cdx.json --fail-on critical  (config .grype.yaml, ignore rules need a reason)
3. Syft: the image built in test-build → sbom-image.cdx.json (OS packages included)
4. Grype: sbom:sbom-image.cdx.json, REPORT-ONLY (no --fail-on; ADR-023 phase 1)
5. Upload both SBOMs + both Grype reports as workflow artifacts
6. Write findings tables to $GITHUB_STEP_SUMMARY: application (gating) and image (report-only)
```

The **same file** that Grype scans is the one uploaded to Dependency-Track (ADR-013).

### `security.yml` → `dependency-track` (only if `vars.DTRACK_URL != ''`; ADR-015)

```text
1. configure-aws-credentials (role sssc-gha-dtrack, OIDC)
2. aws ssm get-parameter --with-decryption /sssc/dtrack/ci-api-key → mask → env
3. Upload BOM
     project name    = sssc-demo-api        (application SBOM; gated)
                       sssc-demo-api-image  (image SBOM; uploaded for visibility, never gated; ADR-023)
     project version = "main" on main, "pr-<number>" on pull requests
     autoCreate      = true
   → receive processing token
4. Poll the token until processing is finished (timeout 5 min → fail)
5. Look up the project UUID by name + version
6. Read policy violations (unsuppressed) and findings
7. Write a summary table: violations by state (FAIL / WARN / INFO), findings by severity, link to the project
8. Exit 1 if any unsuppressed violation of the APPLICATION project has state FAIL
```

Script: `security/scripts/dtrack-upload-and-gate.sh` (bash + curl + jq), runnable locally with the same
arguments, which helps debugging and the demo.

**Checked against Dependency-Track 5.1.2 in the local spike** ([spike/README.md](../spike/README.md), ADR-024):

- The endpoints are those of v4: `POST /api/v1/bom`, `GET /api/v1/event/token/{token}`,
  `GET /api/v1/project/lookup`, `GET /api/v1/violation/project/{uuid}`, `GET /api/v1/finding/project/{uuid}`.
- The token tracks import, vulnerability analysis **and** policy evaluation. The script waits for status
  `COMPLETED` (not just `processing: false`, which a failed import also reports) and then reads violations.
- Lists return 100 items by default; the script reads every page.
- Project metrics are computed asynchronously. The gate reads **violations**, not metric counters.

### `infrastructure.yml`

| Event | Steps |
|-------|-------|
| PR | `terraform fmt -check` → `init -backend=false` → `validate` → `tflint` (none of these need AWS) → `plan` (plan role, **only if** `vars.TF_PLAN_ROLE_ARN` is set) → plan summary in job summary |
| Push to `main` | `plan` → **environment `poc` approval** → two-phase `apply` (below) |
| `workflow_dispatch`, `action = apply` | Start a work session: `plan` → approval → `apply` with `dtrack_public=false` → wait for `/sssc/dtrack/bootstrap-status = done` (timeout → job fails, nothing exposed) → `apply` with `dtrack_public=true` (ADR-020) |
| `workflow_dispatch`, `action = destroy` + `confirm = destroy-poc` | End a work session: approval → `destroy` (apply role, environment `poc`) |

After the project ends, the AWS account and roles no longer exist. Static checks keep running, and the
AWS-dependent steps switch off because their repository variables are deleted. This is the same pattern as
ADR-015, so Dependabot PRs on a finished repository still go green.

Stretch: IaC scanning (Checkov or Trivy config) on PRs, report-only at first.

## 6. Policies as code

`security/policies/` holds the Dependency-Track policies as JSON. The bootstrap applies them, and they're
reviewed like code.

| Policy | Condition | Violation state |
|--------|-----------|-----------------|
| `block-critical` | Vulnerability severity is CRITICAL | FAIL |
| `warn-high` | Vulnerability severity is HIGH | WARN |
| `license-review` (optional) | License group: strong copyleft, or license unknown | WARN |

Policies apply to every project, so `sssc-demo-api-image` shows violations too. They are informational, because the gate only reads the application project (ADR-023).

The license policy is optional. It shows that Dependency-Track governs more than CVEs, at almost no cost.

### Exceptions process

1. Grype: add an ignore entry to `.grype.yaml` with a comment giving CVE, reason, owner and review date.
2. Dependency-Track: add a suppression with an analysis state and justification.
3. Both happen in a PR, so the exception is reviewed and remains in history.

## 7. Controlled vulnerable scenario (the before/after demo)

`main` is never vulnerable. The demo happens inside one pull request.

```text
PR "demo: add <package>@<old version>"
  commit 1 — add the vulnerable version as a direct dependency
     → sbom-scan: Grype FAIL (Critical)            ← evidence: failed scan
     → dependency-track: FAIL violation visible    ← evidence: Dependency-Track project pr-<n>
  commit 2 — upgrade to the fixed version
     → SBOM regenerated → Grype PASS → Dependency-Track PASS   ← evidence: passing run
  merge (or close; keep the PR as public evidence either way)
```

Candidate packages (**confirm Grype and Dependency-Track rate them Critical before use**):
`minimist@1.2.5` (CVE-2021-44906), `handlebars@4.7.6` (CVE-2021-23369). The vulnerable code path is never
called. The point is to show detection, not exploitation.

Keep a `demo/vulnerable-dependency` tag pointing at commit 1 so the scenario can be replayed.

## 8. Threats considered

| Threat | Mitigation |
|--------|------------|
| Leaked long-lived AWS keys from CI | None exist (OIDC). Roles are bound to the repository and to the event, branch or environment |
| Compromised third-party GitHub Action | SHA pinning, minimal `permissions`, Dependabot updates reviewed as PRs |
| Unreviewed infrastructure change | Branch protection on `main`; manual approval on environment `poc` |
| Subdomain takeover on the company domain (`dtrack.frontward-solutions.com`) | The alias record is destroyed with each environment. At the end of the project, the NS delegation is removed at the parent domain **before** the hosted zone or account is deleted ([runbook §6](runbook.md#end-of-project-final-teardown)) |
| Default Dependency-Track admin credentials exposed | ALB has no forward rules until bootstrap has replaced the default password **and verified** that the default login fails (ADR-020). Health checks are not relied on: an ALB routes after one passing check and fails open |
| Instance replacement makes encrypted settings unreadable | Key encryption key kept in Secrets Manager and restored before every start (ADR-021, ADR-024). With a wrong key, v5 refuses to serve instead of corrupting data |
| Master password rotation breaks database connections | Dependency-Track uses its own `dtrack` user; the master user is for bootstrap only (ADR-022) |
| Brute force against the public Dependency-Track login | Long random admin password; HTTPS only; optional CIDR restriction. WAF and SSO are production improvements |
| Credential theft from the instance (SSRF) | IMDSv2 required |
| Database exposed | Data subnet without an internet route; Security Group reference only; no public access; TLS required |
| Secrets committed to Git | Push protection, gitleaks pre-commit, tfvars ignored |
| Secrets in Terraform state | RDS-managed password; secrets generated on the instance; state bucket private and encrypted |
| Vulnerable dependency merged | Grype gate (always) + Dependency-Track policy gate (while up) |
| New CVE in an already-merged dependency | Dependency-Track re-analysis (while up), weekly scheduled Grype scan, Dependabot |
| Gate silently bypassed through suppressions | Suppressions need a written reason and go through a PR; visible in Git and in the Dependency-Track audit trail |

## 9. Explicitly out of scope (v1)

WAF, SSO for Dependency-Track, image signing and SBOM attestations, SLSA provenance, runtime protection,
SIEM, penetration testing, GuardDuty / Security Hub / Config rules. List them as production improvements;
don't implement them here.
