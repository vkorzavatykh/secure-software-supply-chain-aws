# Runbook

> Replace `<...>` placeholders. The AWS CLI profile is called `sssc` here.

## 0. Prerequisites

### AWS account

| Item | Setting | Why |
|------|---------|-----|
| Account | A dedicated account, used only for this project | Clean teardown, contained blast radius |
| Root user | MFA on; never used day to day | Basic hygiene |
| Daily access | IAM Identity Center user with an admin permission set, used through `aws sso login` | No long-lived access keys on the workstation either |
| Region | `eu-central-1` | All required services are available |
| Budget | AWS Budgets alert, for example USD 40/month with alerts at 50%, 80% and 100% | A forgotten environment shows up within a day |
| Cost visibility | Cost Explorer on; every resource is tagged `Project=sssc-poc` | Cost per project shows up in billing |

### DNS

Access to the parent domain's DNS provider. The `dtrack` NS records are added there once at the start
(§1) and removed once at the end (§6). Nothing else on the parent domain changes (ADR-011).

### GitHub repository

- Secret scanning and push protection on; Dependabot alerts and security updates on.
- A ruleset on `main`: pull request required, status checks required, no force-push.
- Environment `poc` with a required reviewer. This is the manual approval before `terraform apply`.
- Repository variables (not secrets) are filled in after the bootstrap (§1). No AWS keys are stored in
  GitHub (ADR-005).
- Commits use the GitHub `noreply` address, and the pre-commit hooks (gitleaks, `terraform fmt`, tflint)
  are installed before the first commit: `pre-commit install`.

### External accounts

An NVD API key (free, requested from NIST) makes Dependency-Track's first vulnerability mirror much faster.
It is stored in SSM Parameter Store (§1), never in Git.

### Local tools

| Tool | Version | Used for |
|------|---------|----------|
| Terraform | pinned in `.terraform-version` (≥ 1.10 for S3-native state locking) | Infrastructure as Code |
| AWS CLI v2 + Session Manager plugin | latest | SSO login, `aws ssm start-session` |
| Node.js | pinned in `.nvmrc` (current LTS) | Demo application |
| Docker | latest | Image build, local Dependency-Track |
| Syft, Grype | the versions pinned in `.github/workflows/security.yml` | SBOM and scanning, with the same results as CI |
| jq, curl | any recent | Dependency-Track API scripts |
| gh | latest | Repository settings, variables, workflow runs |
| pre-commit, gitleaks, tflint | latest | Local guardrails before anything reaches GitHub |

## 1. One-time bootstrap (workstation, admin SSO credentials)

```bash
aws sso login --profile sssc
export AWS_PROFILE=sssc

# NVD API key: once, by hand, outside Terraform
aws ssm put-parameter --name /sssc/dtrack/nvd-api-key --type SecureString --value '<key>'

cd infrastructure/bootstrap
terraform init
terraform apply          # state bucket, GitHub OIDC provider, CI roles, hosted zone, ACM certificate

# One-time DNS delegation (ADR-011): while apply waits for certificate validation,
# add these as NS records for "dtrack" at the parent domain's DNS provider
# (frontward-solutions.com). This is the only change ever made to the parent domain.
terraform output dtrack_zone_name_servers
# If apply times out before the delegation propagates, simply run `terraform apply` again.

# Hand the outputs to GitHub as repository VARIABLES (not secrets; none of these is sensitive)
gh variable set AWS_REGION        --body eu-central-1
gh variable set AWS_ACCOUNT_ID    --body <account-id>
gh variable set TF_PLAN_ROLE_ARN  --body <output>
gh variable set TF_APPLY_ROLE_ARN --body <output>
gh variable set DTRACK_ROLE_ARN   --body <output>
gh variable set TF_STATE_BUCKET   --body <output>
```

The bootstrap stack is **never destroyed** during normal work.

## 2. Work-session routine

The environment costs about USD 0.21/hour, so it only runs during work sessions
([README → Deployment](../README.md#deployment)).

### Start a session

```bash
gh workflow run infrastructure.yml -f action=apply     # then approve the "poc" environment in GitHub
# The job applies with dtrack_public=false, waits for bootstrap-status = done, then applies with
# dtrack_public=true (ADR-020). If bootstrap times out, the job fails and nothing is exposed.

# Locally, the same two phases:
#   cd infrastructure/environments/poc
#   terraform apply -var dtrack_public=false
#   aws ssm get-parameter --name /sssc/dtrack/bootstrap-status --query Parameter.Value --output text  # → done
#   terraform apply -var dtrack_public=true
# (The first start can be slow because of vulnerability DB mirroring.)

gh variable set DTRACK_URL --body https://dtrack.<domain>   # turns on the Dependency-Track CI stage
```

### End a session

```bash
gh variable delete DTRACK_URL                                # CI stays green without the server
gh workflow run infrastructure.yml -f action=destroy -f confirm=destroy-poc
# then run the leftover check (§6)
```

## 3. First-run configuration

**Automated** by the instance bootstrap (ADR-020): admin password, `ci` team and API key, policies, NVD
API key setting, then a check that the default login fails. Nothing to do by hand.

**Manual fallback** (only if automation is disabled or broken; record its use as a limitation):

1. Keep `dtrack_public=false`, so the ALB forwards nothing. Work through SSM port forwarding instead
   (§5): forward 8080 (UI) and 8081 (API) to localhost.
2. Open `http://localhost:8080`, log in with the default credentials, and set a long random password.
   Store it in `sssc/dtrack/admin`.
3. Administration → Teams → create `ci` with the permissions from [security §3](security.md#3-identities-and-permissions);
   generate an API key and store it:
   `aws ssm put-parameter --name /sssc/dtrack/ci-api-key --type SecureString --overwrite --value '<key>'`
4. Policy Management → create the policies from `security/policies/`.
5. Confirm the default login fails, then `terraform apply -var dtrack_public=true`.

## 4. Verify a deployment

- [ ] During phase 1, `curl -s -o /dev/null -w '%{http_code}' https://dtrack.<domain>/api/version` returns
      `503` (ADR-020 barrier).
- [ ] After phase 2, `https://dtrack.<domain>` loads with a valid certificate; `http://` redirects to HTTPS.
- [ ] Login works with the password from `sssc/dtrack/admin`; the default password **doesn't**.
- [ ] Policies `block-critical` and `warn-high` exist.
- [ ] `/sssc/dtrack/ci-api-key` exists.
- [ ] Both ALB target groups are healthy.
- [ ] Logs are arriving: `aws logs tail /sssc/dependency-track --since 10m`.
- [ ] A manual run of the `ci.yml` workflow uploads an SBOM and the project appears in Dependency-Track.

## 5. Access

```bash
# Admin password for the UI
aws secretsmanager get-secret-value --secret-id sssc/dtrack/admin --query SecretString --output text

# Instance ID
aws ec2 describe-instances --filters Name=tag:Name,Values=sssc-dtrack Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text

# Shell (no SSH)
aws ssm start-session --target <instance-id>

# Reach the apiserver directly, bypassing the ALB (debugging)
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8081"],"localPortNumber":["8081"]}'
# then: curl http://localhost:8081/api/version

# Rotate the application database password (ADR-022). The master password rotates by itself and
# doesn't affect Dependency-Track. Run on the instance (SSM shell):
#   1. NEW=$(openssl rand -base64 32)
#   2. ALTER ROLE dtrack PASSWORD '<NEW>'   (one-off postgres container, master secret read now)
#   3. aws secretsmanager put-secret-value --secret-id sssc/dtrack/db-app --secret-string "$NEW"
#   4. Re-render /opt/dtrack/.env and: sudo systemctl restart dtrack
#   5. Check: aws logs tail /sssc/dependency-track --since 5m (no authentication errors)
# Scripted as deployment/scripts/rotate-db-app-password.sh.

# Run the gate script locally against the live server
security/scripts/dtrack-upload-and-gate.sh --url https://dtrack.<domain> --sbom sbom.cdx.json \
  --project sssc-demo-api --version local
```

## 6. Teardown and leftover check

After `destroy`, check that nothing billable remains:

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=sssc-poc \
  --query 'ResourceTagMappingList[].ResourceARN'
```

(Deleted resources can appear in this list for a short time. Re-check after a few minutes.)

| Check | Why it can be left over |
|-------|-------------------------|
| NAT Gateways, Elastic IPs | Most expensive leftover if a destroy fails halfway |
| Load balancers | Same |
| RDS instances **and manual or final snapshots** | Snapshots aren't deleted with the instance |
| EBS volumes | Orphaned if an instance was terminated outside Terraform |
| Secrets Manager secrets "scheduled for deletion" | Blocks re-creating a secret with the same name next session. Terraform uses `recovery_window_in_days = 0` for the `sssc/dtrack/*` secrets (admin, db-app, secret-key) |
| CloudWatch log groups | Only if created by the Docker log driver instead of Terraform (Terraform should own it) |

Glance at Billing → Bills (current month) after the first two teardowns to confirm the cost really drops
to near zero.

### End of project (final teardown)

Once the evidence is captured, there's no permanently running demo. Remove everything, **in
this order**:

1. `gh variable delete DTRACK_URL`, then destroy the environment (session end, as above) and run the
   leftover check.
2. **Remove the `dtrack` NS records at the parent domain's DNS provider** and wait for the change to
   propagate. This must happen *before* step 3. A delegation that points to a deleted Route 53 zone is a
   known subdomain-takeover pattern, and here it would be on the company domain.
3. Destroy the bootstrap stack: hosted zone, certificate, OIDC provider, CI roles, state bucket. Empty the
   versioned state bucket first, or set `force_destroy` on it for this run.
4. Delete the remaining repository variables (`gh variable list`). CI then runs only the static checks and
   the Grype gate, and stays green ([security §5](security.md#5-pipeline)).
5. Close the AWS account, or keep it for the next project. Either way, step 2 must already be
   done.

## 7. Troubleshooting

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| ALB returns 502/503 | Target not healthy yet (first vulnerability DB mirror), wrong port, Security Group | Target group health; `docker ps`; `aws logs tail` |
| Dependency-Track restarts or is very slow | Memory too low for the apiserver | `docker stats` over SSM; container memory limit; instance type |
| Database connection errors in the apiserver logs | Security Group rule, TLS setting, wrong endpoint or secret | From the instance: `timeout 3 bash -c '</dev/tcp/<rds-endpoint>/5432' && echo open` |
| Instance not visible in Session Manager | No egress (NAT route), missing `AmazonSSMManagedInstanceCore`, agent not running | Fleet Manager; private route table; instance profile |
| CI: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `sub` claim doesn't match the trust policy (branch / PR / environment), or `id-token: write` missing | Compare the job's event with [security §3](security.md#3-identities-and-permissions) |
| CI: Dependency-Track 401/403 | Missing or wrong key; team missing a permission | `ci` team permissions in the UI |
| CI: polling the token times out | Initial mirroring still running; analysis slow | Wait for bootstrap-status `done`; raise the timeout |
| `terraform` reports a state lock | A previous run was interrupted | Make sure no run is active, then `terraform force-unlock <lock-id>` |
| Every request answers `503 Starting` | `dtrack_public` is still `false`: bootstrap not finished, or phase 2 not applied | bootstrap-status parameter; cloud-init and container logs |
| After instance replacement: NVD mirroring fails, or settings show decryption errors | Secret key not restored, so Dependency-Track generated a new one (ADR-021) | Does `sssc/dtrack/secret-key` have a value? Is `ALPINE_SECRET_KEY_PATH` set in `.env`? |
| `password authentication failed for user "dtrack"` | `.env` is out of date after a rotation | Re-render `.env` from `sssc/dtrack/db-app` and restart (rotation procedure, §5) |
| ACM certificate stuck in "Pending validation" | Validation record missing or not propagated | DNS record for the validation CNAME; delegation of the zone |
