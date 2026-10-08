# Infrastructure

Terraform for the AWS side of the project. The design is in [docs/architecture.md](../docs/architecture.md)
and the decisions behind it are in [docs/decisions.md](../docs/decisions.md).

```text
infrastructure/
├── bootstrap/          applied once from a workstation; never destroyed during normal work
├── modules/
│   ├── network/        VPC, subnets in two AZs, NAT Gateway, route tables, Security Groups
│   ├── database/       RDS PostgreSQL, subnet group, parameter group (TLS forced)
│   ├── compute/        EC2 instance, instance role, secret containers, bootstrap status, log group
│   └── edge/           ALB, HTTPS listener with the startup barrier, target groups, alias record
└── environments/
    └── poc/            composes the modules, plus user_data and alarms; created and destroyed per session
```

The instance bootstrap scripts live in [`deployment/user-data/`](../deployment/user-data/) and are rendered
into gzip-compressed cloud-init user_data by `environments/poc/user-data.tf`.

## Stacks

| Stack | Lifecycle | Contains |
|-------|-----------|----------|
| `bootstrap` | Applied once with admin SSO credentials; destroyed at the end of the project | State bucket, GitHub OIDC provider, CI roles, Route 53 zone with CAA record, ACM certificate |
| `environments/poc` | Applied and destroyed per work session by the `infrastructure` workflow | The Dependency-Track environment |

The split exists because CI can't create the identity it authenticates with (ADR-008), and because
`terraform destroy` on the environment must never touch the long-lived parts.

## State

- **`environments/poc`:** S3 backend in the bootstrap bucket, key `poc/terraform.tfstate`, with S3-native
  locking (`use_lockfile = true`, so no DynamoDB table). The bucket is versioned, encrypted, blocks public
  access and refuses non-TLS requests.
- **`bootstrap`:** local state, on purpose. The stack creates the state bucket, so it can't start out
  using it. At the end of the project the bucket is emptied before the stack is destroyed, which would
  delete this stack's own state if it lived there. The local state holds no secrets (no resource in this
  stack has a secret value). Keep a backup copy outside the repository; `*.tfstate` is ignored by Git.

## Validate locally (no AWS account needed)

```bash
terraform fmt -check -recursive infrastructure
for stack in bootstrap environments/poc; do
  terraform -chdir="infrastructure/$stack" init -backend=false -lockfile=readonly
  terraform -chdir="infrastructure/$stack" validate
done
tflint --init --config "$PWD/.tflint.hcl"
tflint --recursive --config "$PWD/.tflint.hcl"
```

## Test locally (no AWS account needed)

`terraform test` checks the security properties the docs promise, without touching AWS:

| Suite | Provider | Checks |
|-------|----------|--------|
| `bootstrap/tests` | Real AWS provider, offline (fake credentials; every resource overridden) | Each CI role trusts only its own event; both Terraform roles explicitly deny secret values and the Dependency-Track keys; the plan role can't write state; the apply role's IAM rights reach only `sssc-ec2`; DNS changes are limited to the apex A record; the state bucket is private, encrypted, versioned and TLS-only |
| `modules/network/tests` | Mocked | Subnet layout; no public IPs; only the app tier reaches the internet, through NAT; no rule opens port 22; tiers reference each other's Security Groups |
| `modules/edge/tests` | Mocked | The startup barrier is closed unless `dtrack_public = true`; when open, `/api/*` reaches the API and everything else the UI; HTTP only redirects |
| `modules/compute/tests` | Mocked | IMDSv2, no public IP, encrypted root volume, replacement on bootstrap change; role name matches the bootstrap scope; secrets with no recovery window; bootstrap status starts at `pending` |
| `modules/database/tests` | Mocked | Not public, encrypted, TLS forced, RDS-managed password, destroyable without leftovers |

```bash
for dir in infrastructure/bootstrap infrastructure/modules/*; do
  terraform -chdir="$dir" init -backend=false && terraform -chdir="$dir" test
done
```

The same checks and tests run in the `infrastructure` workflow on every pull request.
