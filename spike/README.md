# Dependency-Track v5 Spike (local, no AWS)

The spike answers the open questions about Dependency-Track before any of it runs on AWS (backlog P2-07 to
P2-09). It runs the same topology on one machine with Docker: PostgreSQL stands in for RDS, the apiserver
and frontend run as on the instance, and the scripts used here are the ones the instance bootstrap and the
pipeline will use.

Result: **Dependency-Track 5.1.2 is pinned.** Every claim below holds, and the differences from the v4-based
design are recorded in [ADR-024](../docs/decisions.md#adr-024--dependency-track-v5-supersedes-the-v4-specifics-of-adr-021-and-the-nvd-api-key).

## Run it

```bash
spike/run.sh up                   # PostgreSQL → db-init (role and database "dtrack") → apiserver + frontend
spike/run.sh first-run            # admin password, team "ci" + API key, policies, OSV; verifies default login fails
DTRACK_API_KEY=$(cat spike/secrets/ci-api-key) \
  security/scripts/dtrack-upload-and-gate.sh --url http://localhost:8081 \
  --sbom sbom.cdx.json --project sssc-demo-api --version local
spike/run.sh rotate-db-password   # new password for role dtrack, then a restart
spike/run.sh destroy              # removes containers and volumes
```

The UI is at <http://localhost:8080>; log in as `admin` with the password in `spike/secrets/admin-password`.
All secrets live in `spike/secrets/` (ignored by Git) and reach the containers as mounted files.

## Results (2026-10-08, Dependency-Track 5.1.2, PostgreSQL 17.9)

### P2-07: version, API flow, first-run configuration

| Question | Answer |
|----------|--------|
| Which version? | **v5.1.2** (apiserver and frontend, pinned by digest). v5 has been GA since June 2026; v4.14 gets fixes only until about six months after that. v5 keeps the apiserver + frontend pair behind one origin with `/api` routing, so the network and load balancer design is unchanged |
| Does it run as a non-superuser? | Yes. All init tasks (migrations, partition maintenance, seeding) run as `dtrack`, which owns its database and is not a superuser. The migrations' only privileged statement is `CREATE EXTENSION pg_trgm`, a trusted extension the database owner may create |
| Endpoints and permissions | As in v4: login, `forceChangePassword`, teams, permissions, API keys, `PUT/POST /api/v1/policy`, BOM upload, token status, violations and findings. The `ci` team needs `BOM_UPLOAD`, `PROJECT_CREATION_UPLOAD`, `VIEW_PORTFOLIO`, `VIEW_VULNERABILITY`, `VIEW_POLICY_VIOLATION`, exactly the v4 set |
| What does the upload token cover? | Import, vulnerability analysis **and** policy evaluation. Once `/api/v1/event/token/{token}` reports `status: COMPLETED`, findings and violations are complete, so no extra wait is needed. `processing: false` alone isn't enough: a failed import reports it too |
| CycloneDX versions | JSON 1.2 to 1.7 are accepted, so the 1.6 pin in CI is no longer needed |
| Pagination | Lists return 100 items unless asked for more; the gate script reads every page |
| First-run script | `deployment/scripts/dtrack-first-run.sh` works from scratch in about 15 seconds and is idempotent: a second run changes nothing, and the CI API key stays the same |
| Timing from zero | `up` 30 s, first-run 14 s. First OSV mirror (npm) 3.5 to 4 minutes, first NVD mirror about 18 minutes |
| Memory | apiserver about 300 MiB idle and 490 MiB with the NVD and OSV data loaded (v4 needed about 4.5 GiB); PostgreSQL about 290 MiB |

### P2-08: the demo package is Critical in both tools

A lockfile with `minimist@1.2.5` and `handlebars@4.7.6`:

| Tool | Critical | High | Medium | Low | Gate |
|------|---:|---:|---:|---:|------|
| Grype 0.120.1 | 4 | 4 | 2 | 1 | `--fail-on critical` exits 2 |
| Dependency-Track 5.1.2 (OSV) | 4 | 4 | 2 | 1 | `block-critical` FAIL on both packages, `warn-high` WARN on handlebars; the script exits 1 |

`minimist@1.2.5` (GHSA-xvch-5gv4-984h, fixed in 1.2.6) is the cleaner demo: one advisory, one fix. The demo
API itself passes both gates.

### P2-09: the claims of ADR-020 to ADR-022

| Claim | How it was tested | Result |
|-------|-------------------|--------|
| The first-run check proves the default login is gone (ADR-020) | Login with `admin`/`admin` before and after the password change | Both answers are **401**; only the body differs: `FORCE_PASSWORD_CHANGE` before, `INVALID_CREDENTIALS` after. The script checks the body, because a status-only check would pass while the default password still works |
| Encrypted settings survive instance replacement (ADR-021) | Stored a managed secret, referenced it from a data-source config, then deleted the apiserver container **and** its data volume and started a new one with the same key | The secret decrypts on the new instance (the server resolves it when the config is saved: 204; a missing secret gives 400). Projects and findings are untouched, because they live in PostgreSQL |
| ... and break without the key | Started the apiserver with a different key | It refuses to start serving: `IllegalStateException: KEK keyset mismatch`. **But the process stays up and `:9000/health` reports UP**, so Docker marks it healthy while port 8080 never opens. Health checks must use `/api/version` on the API port |
| The key needn't be in the environment | Passed it as `${file::/run/secrets/kek}`, a mounted file | Works; `docker inspect` shows only the reference. Same for the database password |
| The superuser password doesn't affect Dependency-Track (ADR-022) | `ALTER ROLE postgres PASSWORD ...`, restart, upload | Still works: Dependency-Track connects as `dtrack` |
| The application password can be rotated (ADR-022) | `spike/run.sh rotate-db-password`, then an upload; then a start with the old password | Works with the new password; the old one is refused (`password authentication failed for user "dtrack"`) |

### Other findings

- **No NVD API key in v5.** NVD data comes from the public JSON 2.0 feed files, so the hand-made
  `/sssc/dtrack/nvd-api-key` parameter and its permissions go away.
- **OSV must be switched on.** A fresh instance enables only NVD, which matches npm packages poorly.
  First-run enables OSV for npm and starts its first mirror; otherwise the gate would see nothing until the
  scheduled run.
- **Container images: Grype and Dependency-Track see different things.** Grype reports 11 High findings in
  the distroless Debian base, all marked not-fixed or won't-fix by Debian's security tracker. Dependency-
  Track shows none for the image project, even with OSV's Debian data enabled (tested: an 88-second
  mirror). That's another reason for the different roles in ADR-006 and for keeping image findings
  report-only (ADR-023).
- **Failures fail closed.** An invalid API key or an unreachable server makes the gate script exit 2.

## Limitations of the spike

- PostgreSQL runs without TLS here; RDS forces it (`rds.force_ssl = 1`). The JDBC connection over TLS is
  checked on AWS (P4-04).
- Docker Desktop on macOS, not Amazon Linux. The scripts avoid platform-specific tools, and the bootstrap
  runs psql from the same `postgres` image on both.
