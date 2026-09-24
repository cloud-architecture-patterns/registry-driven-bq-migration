# Registry-Driven BigQuery Migration

> Secure multi-tenant BigQuery Prod→QA migration: per-tenant identity isolation, allow-list enforcement, and VPC-SC chaining via a YAML registry.

Reference implementation for the architecture described in:

> **Registry-Driven Identity Isolation for Secure Multi-Tenant Cloud Data Migration Pipelines**
> Preprint: [arXiv — to be published]

---

## The Problem

A shared service account migration pipeline has an unbounded blast radius: one compromised identity can read every onboarded production dataset and write to every QA destination.

## The Architecture

Three composable mechanisms:

1. **APPCODE-scoped identity isolation** — each application code (APPCODE) gets a dedicated migration service account. A YAML registry drives runtime identity resolution in a shared GitHub Actions workflow — zero code changes per new tenant.

2. **Multi-gate approved-data enforcement** — allow-list manifest validated against live source schema before any data moves, plus pre/post-copy scans and row-level security reapplication.

3. **Three-perimeter VPC-SC chaining** — data crosses GCP VPC Service Controls perimeters via per-identity, per-method ingress rules. The migration identity cannot become a generalized perimeter bypass.

```
GitHub Actions Runner
        │
        │  WIF token exchange → bq-migration-sa-<appcode>
        │  (attribute.environment condition blocks cross-APPCODE impersonation)
        │
        ▼
[ PROD VPC-SC Perimeter ]  ──extract──▶  [ GCS Perimeter ]  ──load──▶  [ QA VPC-SC Perimeter ]
  BigQuery (Prod)                          GCS landing bucket             BigQuery (QA staging)
  ingress: this SA only                    ingress: this SA only          → promote to live dataset
```

---

## Repository Layout

```
config/
  appcodes/          # one YAML per APPCODE — SA email, WIF provider, allowed projects
  approved_tables/   # one JSON per dataset — tables approved for migration
  rls/               # one JSON per dataset — row-level security definitions

.github/workflows/
  _bq-migrate.yml    # reusable migration workflow (called by per-APPCODE callers)
  bq-migrate-example.yml  # example caller workflow

scripts/
  pre_copy_validate.sh      # Gate 1: allow-list manifest check
  validate_schema_drift.sh  # Gate 2: schema drift detection
  bq_apply_rls.sh           # Post-copy: RLS reapplication

docs/
  appcode-onboarding.md     # Step-by-step guide for onboarding a new APPCODE
```

---

## Quick Start

### 1. Onboard a new APPCODE

See [docs/appcode-onboarding.md](docs/appcode-onboarding.md) for the full runbook. In summary:

1. Create `bq-migration-sa-<appcode>` in the APPCODE's QA project
2. Grant the custom least-privilege role at the QA project level
3. Grant `roles/bigquery.dataViewer` on the production project
4. Create a WIF pool/provider (or reuse the shared one) and grant `workloadIdentityUser` with an `attribute.environment` IAM condition
5. Create the GCS landing bucket
6. Add `config/appcodes/<appcode>.yml` via a reviewed PR
7. Create a GitHub Actions protected environment named `<appcode>-migration`

### 2. Add a dataset for migration

1. Add `config/approved_tables/<dataset>.json` listing every approved table
2. Add `config/rls/<dataset>.json` with row-level security definitions
3. Add a migration config YAML referencing `appcode`, `source`, and `destination`
4. Open a PR — CODEOWNERS review required

### 3. Trigger a migration

```bash
gh workflow run bq-migrate-example.yml \
  -f config_file=config/migrations/appa-campaigns.yml
```

---

## Security Properties

| Threat | Control | Enforcement |
|---|---|---|
| Compromised SA | Per-APPCODE SA with scoped IAM | GCP IAM (technical) |
| YAML pointing to wrong project | Pre-flight allowlist check | Workflow script — exits non-zero |
| New table auto-copied | Allow-list manifest pre-check | Workflow script — exits non-zero |
| Cross-APPCODE WIF lateral movement | `attribute.environment` IAM condition | GCP token exchange — rejects |
| SA writes to production | No `dataEditor` on prod datasets | GCP IAM (technical) |

All technically-enforced controls fail closed: a failed check exits the run non-zero with no data movement.

---

## Requirements

- GCP project per APPCODE per environment tier
- Workload Identity Federation pool configured for your GitHub org
- VPC Service Controls perimeters (three-perimeter chain — see paper for ingress rule templates)
- GitHub Actions with CODEOWNERS and protected environments

---

## License

Apache 2.0
