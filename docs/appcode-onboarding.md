# APPCODE Onboarding Runbook

This guide walks through adding a new APPCODE to the migration pipeline. Each step must be completed before the first migration run for that APPCODE.

Estimated time: ~1 hour.

---

## Prerequisites

- GCP projects exist for the APPCODE: `<org>-<appcode>-prod-prj-01`, `<org>-<appcode>-qa-prj-01`
- You have `roles/iam.serviceAccountAdmin` and `roles/iam.projectIAMAdmin` in the QA project
- The shared WIF pool and GitHub provider exist (or you will create them in Step 4)
- A change request (CR) has been approved covering this onboarding

---

## Step 1 — Create the migration service account

Create the SA in the APPCODE's **QA project** (not a shared tools project):

```bash
gcloud iam service-accounts create bq-migration-sa-<appcode> \
  --project=<org>-<appcode>-qa-prj-01 \
  --display-name="BQ Migration SA — <APPCODE>"
```

---

## Step 2 — Grant the custom least-privilege role

Bind the custom migration role at the **QA project level**:

```bash
gcloud projects add-iam-policy-binding <org>-<appcode>-qa-prj-01 \
  --member="serviceAccount:bq-migration-sa-<appcode>@<org>-<appcode>-qa-prj-01.iam.gserviceaccount.com" \
  --role="projects/<org>-<appcode>-qa-prj-01/roles/bqMigrationCustom"
```

The custom role (`bqMigrationCustom`) contains only these five permissions:
- `bigquery.jobs.create`
- `bigquery.transfers.get`
- `bigquery.transfers.update`
- `bigquery.datasets.create`
- `bigquery.datasets.delete`

Grant dataset-level `dataEditor` separately for each approved destination dataset (not at project level).

---

## Step 3 — Grant read access on the production project

```bash
gcloud projects add-iam-policy-binding <org>-<appcode>-prod-prj-01 \
  --member="serviceAccount:bq-migration-sa-<appcode>@<org>-<appcode>-qa-prj-01.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataViewer"

gcloud projects add-iam-policy-binding <org>-<appcode>-prod-prj-01 \
  --member="serviceAccount:bq-migration-sa-<appcode>@<org>-<appcode>-qa-prj-01.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"
```

---

## Step 4 — Grant Workload Identity Federation with environment attribute condition

This is the critical step for preventing cross-APPCODE lateral movement.

The `workloadIdentityUser` binding on this SA must include an `attribute.environment` condition scoped to this APPCODE's GitHub Actions environment:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  bq-migration-sa-<appcode>@<org>-<appcode>-qa-prj-01.iam.gserviceaccount.com \
  --project=<org>-<appcode>-qa-prj-01 \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/bq-migration-pool/attribute.repository/your-org/registry-driven-bq-migration" \
  --condition='expression=attribute.environment=="<appcode>-migration",title=<appcode>-env-gate'
```

**Why this matters:** without the `attribute.environment` condition, a WIF token obtained during any workflow run in this repo could impersonate any APPCODE's SA. The condition locks each SA to the specific GitHub Actions protected environment for that APPCODE.

---

## Step 5 — Create the GCS landing bucket

Used for the extract/load hop when source and destination are in separate VPC-SC perimeters:

```bash
gcloud storage buckets create gs://bq-migration-landing-<appcode> \
  --project=<tools-project> \
  --location=<region> \
  --lifecycle-file=lifecycle-2day.json
```

Set a 2-day object lifecycle delete rule so landing files are automatically cleaned up.

---

## Step 6 — Submit VPC-SC ingress rules

Open a change request with your GCP/VPC-SC architecture team to add per-SA ingress rules on:
- The **Prod VPC-SC perimeter**: allow `bq-migration-sa-<appcode>` → `bigquery.googleapis.com` methods `tables.getData`, `jobs.create` on the prod project only
- The **GCS VPC-SC perimeter**: allow `bq-migration-sa-<appcode>` → `storage.googleapis.com` methods `objects.*` on the landing bucket only
- The **QA VPC-SC perimeter**: allow `bq-migration-sa-<appcode>` → `bigquery.googleapis.com` methods `jobs.create`, `tables.updateData`, `transfers.*` on the QA project only

---

## Step 7 — Add the APPCODE registry file

Copy `config/appcodes/appa.yml` to `config/appcodes/<appcode-lowercase>.yml` and fill in your values. Open a PR — CODEOWNERS review and CR reference required.

---

## Step 8 — Create the GitHub Actions protected environment

In the repository settings → Environments → New environment:
- Name: `<appcode>-migration`
- Required reviewers: at least one independent approver
- Deployment branches: restrict to `main`

---

## Step 9 — Smoke test

Run the example caller workflow with a small approved dataset. Verify:
- [ ] WIF token exchange succeeds for this APPCODE's SA
- [ ] Pre-flight allow-list check passes
- [ ] Data appears in the QA staging dataset
- [ ] RLS policies are applied correctly
- [ ] Staging promotes to live dataset
- [ ] Run is green end-to-end
