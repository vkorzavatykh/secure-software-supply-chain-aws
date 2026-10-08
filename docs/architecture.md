# Architecture

> Decisions referenced as ADR-NNN are in [decisions.md](decisions.md). Security boundaries and the
> pipeline are in [security.md](security.md). Operating procedures are in [runbook.md](runbook.md).

## 1. Scope in one paragraph

Terraform provisions a small AWS environment that runs **Dependency-Track** on EC2 (Docker) with **RDS
PostgreSQL** behind an **HTTPS Application Load Balancer**. A small Node.js/TypeScript **demo API** lives in
the same repository. Its job is to produce a realistic dependency tree. GitHub Actions builds and tests it,
generates a CycloneDX SBOM, scans it, uploads it to Dependency-Track and applies a security gate.
**The demo API is built and scanned, not deployed.** Deploying it would add scope without strengthening the
story (ADR-018).

## 2. System context

```text
   Developer ──push / PR──►  GitHub repository
                                   │
                                   ▼
                          GitHub Actions
            ┌──────────────────────┴───────────────────────┐
            │ app pipeline                                  │ infrastructure pipeline
            │ test → build → SBOM → scan → upload → gate    │ fmt → validate → plan → (approve) → apply
            └──────────────┬───────────────────────────────┬┘
                           │ HTTPS + Dependency-Track      │ OIDC → STS AssumeRoleWithWebIdentity
                           │ API key (read from SSM        │ (short-lived credentials, no stored keys)
                           │ via OIDC)                     ▼
                           │                         ┌───────────┐
                           │                         │  AWS APIs │
                           ▼                         └───────────┘
   ┌──────────────────────────────── AWS account (eu-central-1) ─────────────────────────────┐
   │                                                                                         │
   │   Internet ──443──►  ALB  ──8080/8081──►  EC2: Dependency-Track ──5432──► RDS PostgreSQL │
   │                                              (frontend + apiserver)                     │
   │                                                   │                                     │
   │                                                   ├──► Secrets Manager (DB password)    │
   │                                                   ├──► SSM Parameter Store (DT keys)    │
   │                                                   ├──► CloudWatch Logs                  │
   │                                                   └──► NAT ──► Internet (NVD, OSV,      │
   │                                                                 GitHub Advisories,      │
   │   Administrator ── SSM Session Manager (no SSH) ──► EC2         container registry)     │
   └─────────────────────────────────────────────────────────────────────────────────────────┘
```

## 3. Network layout

One VPC, two Availability Zones. The ALB and the RDS subnet group both require subnets in at least two AZs.
Only one EC2 instance and one single-AZ RDS instance run (ADR-002, ADR-003).

| Item | Value |
|------|-------|
| VPC CIDR | `10.20.0.0/16` |
| AZs | `eu-central-1a`, `eu-central-1b` |
| DNS hostnames / resolution | enabled (required for SSM and RDS endpoints) |

| Subnet | AZ a | AZ b | Contains | Route to internet |
|--------|------|------|----------|-------------------|
| Public | `10.20.0.0/24` | `10.20.1.0/24` | ALB, NAT Gateway (AZ a only) | Internet Gateway |
| Private app | `10.20.10.0/24` | `10.20.11.0/24` | EC2 (AZ a) | NAT Gateway (outbound only) |
| Private data | `10.20.20.0/24` | `10.20.21.0/24` | RDS (single-AZ, subnet group spans both) | **none** |

Outbound internet from the EC2 instance is required. Dependency-Track mirrors vulnerability data (NVD,
GitHub Advisories, OSV), Docker pulls images, the OS installs packages, and the SSM agent reaches its
endpoints. One NAT Gateway in AZ a provides this (ADR-007). The data subnets have no internet route at all.

## 4. Security Group matrix

No rule anywhere allows port 22.

| Security Group | Inbound | Outbound |
|----------------|---------|----------|
| `sssc-alb` | 443/tcp from `var.allowed_ingress_cidrs` (default `0.0.0.0/0`); 80/tcp same, redirected to 443 | 8080/tcp, 8081/tcp to `sssc-app` |
| `sssc-app` | 8080/tcp, 8081/tcp from `sssc-alb` only | 443/tcp to `0.0.0.0/0` (feeds, registry, SSM, AWS APIs); 5432/tcp to `sssc-db`; 80/tcp to `0.0.0.0/0` only if OS repositories need it (check and remove if possible) |
| `sssc-db` | 5432/tcp from `sssc-app` only | none |

Rules use Security Group references, not CIDRs, between tiers.

## 5. Load balancer routing

Dependency-Track ships as two containers: the **frontend** (static SPA) and the **apiserver**. One ALB
serves both from the same origin, so the frontend's `API_BASE_URL` can be the public URL itself.

| Listener | Rule | Target group | Container port (host) | Health check |
|----------|------|--------------|----------------------|--------------|
| HTTP :80 | default | redirect 301 → HTTPS | — | — |
| HTTPS :443 | path `/api/*` | `sssc-dt-api` | apiserver (8081) | `GET /api/version` → 200 |
| HTTPS :443 | default | `sssc-dt-ui` | frontend (8080) | `GET /` → 200 |

**Startup barrier (ADR-020).** The forward rules above exist only while `dtrack_public = true`. While it is
`false` (always the case during the first apply of a session), the HTTPS listener's only action is a fixed
`503 Starting` response, so no request can reach the instance before bootstrap has replaced the default
credentials. A health check can't provide this barrier: the ALB routes to a new target after one passing
check, and fails open when all targets are unhealthy.

TLS: ACM certificate for `dtrack.<domain>`, created once in the bootstrap stack with DNS validation in the
delegated hosted zone (ADR-011). The environment only adds an ALB alias record at the zone apex. Use a
current AWS-recommended TLS security policy.

> Check the health endpoint against the pinned Dependency-Track version. Newer versions also expose
> dedicated health endpoints, and the ALB health check should use whichever is the documented
> liveness/readiness endpoint.

## 6. Compute: the EC2 instance

| Setting | Value | Reason |
|---------|-------|--------|
| AMI | Amazon Linux 2023, latest, looked up by SSM public parameter | SSM agent preinstalled; no AMI ID hard-coded |
| Type | `t3.medium` (x86_64, 4 GiB) | The Dependency-Track v5 apiserver needs about 490 MiB with the vulnerability data loaded (ADR-024; v4 needed about 4.5 GiB). ARM (`t4g`) is a possible later saving once image support is confirmed |
| Root volume | 30 GiB gp3, encrypted | Docker images and container logs |
| IMDS | IMDSv2 **required**, hop limit 2 (containers use the role) | Blocks SSRF-style credential theft through IMDSv1 |
| Instance profile | `AmazonSSMManagedInstanceCore` + scoped inline policy (see [security §3](security.md#3-identities-and-permissions)) | SSM access, secrets read, logs |
| Key pair | **none** | Access only through Session Manager (ADR-004) |
| `user_data_replace_on_change` | `true` | Any bootstrap change replaces the instance, so it's never hand-patched |

### Bootstrap sequence (cloud-init / user_data)

```text
1. dnf update (security), install docker + compose plugin, enable docker
2. Configure the Docker awslogs log driver → CloudWatch log group /sssc/dependency-track
3. Key encryption key (ADR-021, ADR-024): if sssc/dtrack/secret-key has no value yet, generate one
   (openssl rand -base64 32) and store it there BEFORE Dependency-Track ever starts; then restore it to
   the secret file /opt/dtrack/secrets/kek
4. Database (ADR-022): read the RDS master secret at this moment; run deployment/scripts/db-init.sh in a
   one-off `postgres` container to create role + database `dtrack` if missing; generate the `dtrack`
   password once, store it in sssc/dtrack/db-app (on later boots, read it from there), write it to
   /opt/dtrack/secrets/db-password
5. Render /opt/dtrack/docker-compose.yml (from Terraform templatefile); secrets reach the apiserver only
   as mounted files through ${file::...}, never as environment values
6. Install a systemd unit that runs `docker compose up` on boot
7. Start Dependency-Track; poll GET /api/version on localhost until ready (with timeout). Not :9000/health,
   which reports UP even when a wrong key keeps the API from starting (ADR-024)
8. First-run configuration against localhost (deployment/scripts/dtrack-first-run.sh, ADR-020),
   idempotent: change the default admin password (new password → sssc/dtrack/admin), create the CI team +
   API key → SSM /sssc/dtrack/ci-api-key, apply the policies from security/policies/, enable OSV for npm
9. The same script verifies that a login with the default credentials is REJECTED (body
   INVALID_CREDENTIALS, not just 401), then the bootstrap signals completion (log line + SSM parameter
   /sssc/dtrack/bootstrap-status = done)
```

Until the second apply sets `dtrack_public = true`, the ALB has no route to the instance (§5).

Who owns which parameter matters for the barrier. Terraform creates `/sssc/dtrack/bootstrap-status` with
the value `pending` and destroys it with the environment, so a `done` left over from an earlier session
can never open the barrier early. Terraform does **not** manage `/sssc/dtrack/ci-api-key`. The instance
writes it, because a Terraform-managed SecureString is copied into state on every refresh, and the plan
role can read state (ADR-019, point 4). The destroy job deletes it ([runbook §6](runbook.md#6-teardown-and-leftover-check)).

The compose file and scripts come from the repository (`deployment/`) through `templatefile`, so the
running configuration is always traceable to a commit (ADR-009).

### Dependency-Track configuration (key settings)

Pinned and verified in the local spike ([spike/README.md](../spike/README.md), ADR-024).

| Setting | Value |
|---------|-------|
| Images | `dependencytrack/apiserver:5.1.2` and `dependencytrack/frontend:5.1.2`, pinned by digest |
| Database | `DT_DATASOURCE_URL=jdbc:postgresql://<rds-endpoint>:5432/dtrack?sslmode=require`, `DT_DATASOURCE_USERNAME=dtrack`, `DT_DATASOURCE_PASSWORD=${file::/run/secrets/db-password}` (ADR-022) |
| Key encryption key | `DT_SECRET_MANAGEMENT_DATABASE_KEK=${file::/run/secrets/kek}` (restored from Secrets Manager; ADR-021, ADR-024) |
| Telemetry | `DT_TELEMETRY_SUBMISSION_DEFAULT_ENABLED=false` (it only takes effect on the first start) |
| Vulnerability data | NVD (public feed files, no API key) is on by default; first-run enables OSV for npm |
| Ports | apiserver 8080 in the container (8081 on the host), frontend 8080; management and health on 9000, not exposed |
| Frontend | `API_BASE_URL=https://dtrack.<domain>` |
| Memory | Container limit 2 GiB for the apiserver (it uses about 490 MiB with the data loaded) |

## 7. Data: RDS PostgreSQL

| Setting | Value | Reason |
|---------|-------|--------|
| Engine | PostgreSQL, a major version supported by the pinned Dependency-Track version | — |
| Class | `db.t4g.micro` (upgrade to `small` if the initial mirroring is too slow) | Cost |
| Deployment | Single-AZ; subnet group across both data subnets | POC; Multi-AZ listed as a production improvement |
| Public access | `false` | Data tier has no internet route |
| Storage | 20 GiB gp3, encrypted (AWS-managed KMS key), autoscaling off | — |
| Master password | `manage_master_user_password = true` (RDS-managed secret in Secrets Manager; rotated every 7 days by default) | Password never appears in Terraform code, variables or state (ADR-010). **Used only by the bootstrap** (ADR-022) |
| Application user | Role `dtrack`, owner of database `dtrack`; password in `sssc/dtrack/db-app`; rotation by runbook procedure | Not affected by master rotation; not `rds_superuser` (ADR-022) |
| Backups | 1–7 day retention | Shows the restore capability without cost |
| Deletion | `deletion_protection = false`, `skip_final_snapshot` driven by a variable | The environment must be destroyable in one command |
| Parameter group | `rds.force_ssl = 1` | Encrypted in transit; the JDBC URL uses `sslmode=require` |

The EC2 instance holds **no essential state of its own** (ADR-021, ADR-024). Projects, findings, audit
decisions and the vulnerability data live in RDS. The key encryption key, which protects the secrets
Dependency-Track keeps in that database, lives in Secrets Manager. Nothing in the data directory is
essential: v5 keeps sessions in the database and uses the directory only for temporary files. Replacing
the instance (new AMI, changed bootstrap) loses nothing, and showing that, including a stored secret that
still decrypts, is part of the demo (P4-05). The local spike has already shown it with a deleted container
and data volume ([spike/README.md](../spike/README.md#p2-09-the-claims-of-adr-020-to-adr-022)).

## 8. Logging and monitoring (MVP)

- Container stdout/stderr → CloudWatch Logs, 7-day retention.
- ALB access logs: off in the MVP (they need an S3 bucket and policy); listed as an improvement.
- CloudWatch alarms (email through SNS): ALB `UnHealthyHostCount > 0` for 5 minutes; EC2 status check
  failed; RDS `FreeStorageSpace` low.
- No dashboards, tracing or SIEM in the MVP.

## 9. Terraform layout and state

```text
infrastructure/
├── bootstrap/                 # applied ONCE, locally, with admin SSO credentials
│   ├── main.tf                # S3 state bucket, GitHub OIDC provider, CI IAM roles,
│   └── ...                    # Route 53 zone dtrack.<domain> + CAA record, ACM certificate
├── modules/
│   ├── network/               # VPC, subnets, routes, IGW, NAT, SGs
│   ├── database/              # RDS, subnet group, parameter group
│   ├── compute/               # EC2, instance profile, user_data, SSM params
│   └── edge/                  # ALB, listeners, target groups, alias record (cert from bootstrap)
└── environments/
    └── poc/                   # composes modules; backend "s3" with use_lockfile = true
```

- **Two stacks with different lifecycles.** `bootstrap` stays permanently (it's cheap, and CI can't run
  without it; the zone's NS records and the validated certificate must not change between sessions). `poc`
  is created and destroyed per work session.
- **State:** S3 bucket with versioning, encryption and public access blocked, and S3-native locking
  (`use_lockfile = true`, Terraform ≥ 1.10). No DynamoDB table (ADR-008).
- The bootstrap stack's own state is local or in the same bucket under a separate key. Document whichever
  you choose.
- **Tags:** `default_tags` in the provider: `Project=sssc-poc`, `Environment=poc`, `ManagedBy=terraform`,
  `Repository=vkorzavatykh/secure-software-supply-chain-aws`.
- **Naming prefix:** `sssc-` for every resource.

## 10. Sequences

### A. Environment deployment

```text
Engineer ──(PR touching infrastructure/)──► infra workflow: fmt, validate, tflint, plan (plan role)
       ◄── plan posted to PR summary
Engineer ──merge to main──► infra workflow: plan → waits for environment "poc" approval
Engineer ──approve──► phase 1: apply, dtrack_public=false (apply role) → AWS resources; listener answers 503
EC2 boots ──► bootstrap §6 ──► default credentials replaced and verified ──► bootstrap-status = done
Workflow ──waits for done──► phase 2: apply, dtrack_public=true → forward rules created (ADR-020)
Engineer ──sets repository variable DTRACK_URL──► app pipeline now uploads SBOMs
```

### B. Application change (details in [security §5](security.md#5-pipeline))

```text
PR ──► test ──► build ──► SBOM (Syft) ──► scan + gate (Grype) ──► [if DTRACK_URL set]
       OIDC → read DT API key from SSM ──► upload SBOM ──► wait for analysis ──► policy gate ──► PASS/FAIL
```

## 11. What a production version would change

Summarised in the README's [Limitations](../README.md#limitations) and
[Future Improvements](../README.md#future-improvements).

| Area | POC | Production |
|------|-----|------------|
| Lifecycle | Created for a work session and destroyed afterwards; all Dependency-Track data is discarded each time ([runbook §2](runbook.md#2-work-session-routine)) | Runs permanently; data protected with backups, deletion protection and tested restores |
| Availability | 1 EC2, single-AZ RDS, 1 NAT | Auto Scaling group / ECS service across AZs, Multi-AZ RDS, NAT per AZ |
| Private AWS access | Through NAT | VPC interface endpoints (SSM, Secrets Manager, Logs), so less traffic leaves the VPC |
| Edge | ALB open to the internet on 443 | WAF, IP allow-lists or private access via VPN / Zero Trust; SSO for the Dependency-Track UI |
| Database credentials | Dedicated `dtrack` user; rotation by runbook procedure | Automated rotation of the application user with a reload hook |
| Observability | Logs + 3 alarms | Dashboards, metrics, access logs, central log retention |
| Supply chain | Application SBOM gate + report-only image scan | Image findings blocking for fixable Critical (ADR-023 phase 2), signed images and SBOM attestations (Sigstore/cosign), SLSA provenance, IaC scanning |
| CI permissions | Iteratively scoped apply role | Permission boundaries, per-module roles, plan/apply separation per account |
