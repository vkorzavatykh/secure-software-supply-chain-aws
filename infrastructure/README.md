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

The same checks run in the `infrastructure` workflow on every pull request.
