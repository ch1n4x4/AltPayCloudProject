# AltPay Cloud Deployment Troubleshooting & Operational Runbook

![Platform](https://img.shields.io/badge/Platform-AWS_eu--west--1-232F3E?style=flat-square)
![IaC](https://img.shields.io/badge/IaC-Terraform-844FBA?style=flat-square)
![Status](https://img.shields.io/badge/Runbook-Verified-success?style=flat-square)

> **Document Purpose:** This operational runbook documents the real-world technical issues encountered while provisioning, hardening, and validating the AltPay infrastructure on AWS Free Tier with Terraform, along with their root-cause analyses and exact resolutions.

---

## Table of Contents
- [Issue 1: KMS Key Policy Rejecting CloudWatch Log Group Encryption](#issue-1-kms-key-policy-rejecting-cloudwatch-log-group-encryption)
- [Issue 2: RDS PostgreSQL Engine Version & Free-Tier Backup Retention Errors](#issue-2-rds-postgresql-engine-version--free-tier-backup-retention-errors)
- [Issue 3: AWS SSM Session Manager Plugin Not Found on Windows Workstation](#issue-3-aws-ssm-session-manager-plugin-not-found-on-windows-workstation)
- [Issue 4: Empty `$RDS_HOST` Variable Inside Remote SSM Session (`/dev/tcp//5432: Invalid argument`)](#issue-4-empty-rds_host-variable-inside-remote-ssm-session-devtcp5432-invalid-argument)
- [Issue 5: Windows PowerShell `curl` Alias & JSON Quote Stripping on `POST` Requests](#issue-5-windows-powershell-curl-alias--json-quote-stripping-on-post-requests)
- [Issue 6: `nc` (nmap-ncat) Not Pre-Installed on Minimal Amazon Linux 2023 AMI](#issue-6-nc-nmap-ncat-not-pre-installed-on-minimal-amazon-linux-2023-ami)

---

## Issue 1: KMS Key Policy Rejecting CloudWatch Log Group Encryption

### Symptom
During `terraform apply`, creation of the `aws_cloudwatch_log_group.app_logs` (`/altpay/app/portal`) and `aws_cloudwatch_log_group.vpc_flow_logs` (`/altpay/vpc/flow-logs`) resources failed with an `AccessDeniedException`:
```text
Error: associating CloudWatch Logs Log Group (/altpay/app/portal) KMS Key: operation error CloudWatch Logs: AssociateKmsKey, https response error StatusCode: 400, api error AccessDeniedException: The specified KMS key does not allow CloudWatch Logs to encrypt log data.
```

### Root Cause
While AWS CloudTrail only requires `kms:GenerateDataKey*` and `kms:Decrypt`, the regional CloudWatch Logs service principal (`logs.eu-west-1.amazonaws.com`) explicitly tests for `kms:Encrypt` and `kms:ReEncrypt*` permissions in the KMS Customer Managed Key (CMK) policy before associating a CMK with a log group.

### Resolution
Updated the `AllowCloudTrailAndLogsToEncrypt` statement in `terraform/kms_secrets.tf` to include `"kms:Encrypt"` and `"kms:ReEncrypt*"`:

```hcl
      {
        Sid       = "AllowCloudTrailAndLogsToEncrypt"
        Effect    = "Allow"
        Principal = {
          Service = [
            "cloudtrail.amazonaws.com",
            "logs.${var.aws_region}.amazonaws.com"
          ]
        }
        Action = [
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
```

---

## Issue 2: RDS PostgreSQL Engine Version & Free-Tier Backup Retention Errors

### Symptom
`terraform apply` returned an `InvalidParameterCombination` error when provisioning `aws_db_instance.postgres`:
1. Specifying `engine_version = "16.3"` failed because AWS had deprecated `16.3` in favor of newer 16.x minor releases (`16.13`) in `eu-west-1`.
2. Certain AWS Free-Tier accounts restrict automated backup retention periods above 1 day on free-tier `db.t3.micro` instances.

### Root Cause
Hardcoding a specific minor patch version (`16.3`) makes Terraform brittle when AWS rotates default minor versions in a region, and Free-Tier account guardrails enforce strict parameter bounds on `db.t3.micro`.

### Resolution
Updated `terraform/rds.tf` to specify the major engine branch (`engine_version = "16"`, which AWS automatically resolved to `16.13`) and set `backup_retention_period = 1` with `copy_tags_to_snapshot = true` and `storage_encrypted = true`:

```hcl
resource "aws_db_instance" "postgres" {
  identifier              = "${var.project_name}-postgres-db"
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = "db.t3.micro"
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.altpay_cmk.arn
  backup_retention_period = 1
  backup_window           = "03:00-04:00"
  copy_tags_to_snapshot   = true
  ...
}
```

![RDS PostgreSQL 16.13 Deployed](./screenshots/rds%20database.png)
*Figure 1: RDS PostgreSQL 16.13 (`altpay-postgres-db`) successfully running in `eu-west-1a` with KMS storage encryption enabled.*

---

## Issue 3: AWS SSM Session Manager Plugin Not Found on Windows Workstation

### Symptom
Running `aws ssm start-session --target i-00745caf3b19355fd` in Windows PowerShell returned:
```text
SessionManagerPlugin is not found. Please refer to SessionManager Documentation here: [http://docs.aws.amazon.com/console/systems-manager/session-manager-plugin-not-found](http://docs.aws.amazon.com/console/systems-manager/session-manager-plugin-not-found)
```

### Root Cause
The AWS CLI v2 includes the `aws ssm` control-plane commands, but interactive WebSocket/SSM data-channel tunneling requires the standalone `session-manager-plugin` binary to be installed and registered in the system `PATH`.

### Resolution
Downloaded and silently installed the official AWS Session Manager Plugin installer in PowerShell and refreshed the session `PATH`:

```powershell
Invoke-WebRequest `
  -Uri "[https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe](https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe)" `
  -OutFile "$env:TEMP\SessionManagerPluginSetup.exe"

Start-Process -FilePath "$env:TEMP\SessionManagerPluginSetup.exe" -ArgumentList "/quiet" -Wait
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
session-manager-plugin
```

![Session Manager Plugin Installation](./screenshots/install%20aws%20session%20manager%20plugin.png)
*Figure 2: Successful installation and verification of the Session Manager Plugin in Windows PowerShell.*

---

## Issue 4: Empty `$RDS_HOST` Variable Inside Remote SSM Session (`/dev/tcp//5432: Invalid argument`)

### Symptom
After connecting to the private EC2 instance via `aws ssm start-session`, running the Bash TCP check produced the following error:
```text
sh-5.2$ timeout 3 bash -c "</dev/tcp/$RDS_HOST/5432" && echo "SUCCESS: Connected to RDS on 5432"
bash: line 1: : Name or service not known
bash: line 1: /dev/tcp//5432: Invalid argument
```

### Root Cause
`$RDS_HOST` was defined in the local Windows PowerShell session (`$RDS_HOST = ($RDS_ENDPOINT -split ':')[0]`). Local PowerShell environment variables are not passed across the AWS SSM WebSocket tunnel into the remote Amazon Linux `sh-5.2$` shell, causing Bash to expand `$RDS_HOST` as an empty string (`""`) and evaluate `/dev/tcp//5432`.

### Resolution
Exported `RDS_HOST` directly inside the remote `sh-5.2$` shell session, verified DNS resolution to the private DB subnet IP (`10.0.21.253`), and re-ran both the `/dev/tcp` and `pg_isready` checks:

```bash
export RDS_HOST="altpay-postgres-db.czek08ukwcnb.eu-west-1.rds.amazonaws.com"
echo "Testing host: $RDS_HOST"
getent hosts "$RDS_HOST"

# 1. Allowed Flow (Port 5432) -> Succeeds
timeout 3 bash -c "</dev/tcp/$RDS_HOST/5432" && echo "SUCCESS: Connected to RDS on port 5432"
pg_isready -h "$RDS_HOST" -p 5432

# 2. Disallowed Flow (Port 22) -> Blocked after 3s timeout
timeout 3 bash -c "</dev/tcp/$RDS_HOST/22" && echo "UNEXPECTED SUCCESS" || echo "BLOCKED: Connection to RDS on port 22 timed out / rejected as expected"
```

![Verified Allowed and Disallowed Ports in SSM](./screenshots/verify%20allowed%20and%20disallowed%20ports.png)
*Figure 3: Exporting `RDS_HOST` inside the remote SSM session and proving port 5432 connectivity (`SUCCESS` + `accepting connections`) alongside port 22 blocking.*

---

## Issue 5: Windows PowerShell `curl` Alias & JSON Quote Stripping on `POST` Requests

### Symptom
1. Running `curl -I` in Windows PowerShell 5.1 invoked `Invoke-WebRequest` instead of the native `curl` binary, prompting for parameters or failing on self-signed TLS certificates.
2. Passing inline JSON via `-d '{"filename":"invoice.pdf"}'` in PowerShell stripped inner double quotes before reaching `curl.exe`, resulting in malformed JSON payloads.

### Root Cause
Windows PowerShell aliases `curl` to `Invoke-WebRequest` and parses double quotes inside single-quoted strings differently when invoking native Win32 executables (`curl.exe`).

### Resolution
Explicitly invoked `curl.exe` with the `-k` flag and piped the JSON string into standard input using `--data-binary '@-'`:

```powershell
# Valid upload check using stdin piping (--data-binary '@-')
'{"filename":"invoice.pdf","content_type":"application/pdf"}' | `
  curl.exe -k -s -i -X POST "$ALB_DNS/api/presigned-upload" `
  -H "Content-Type: application/json" `
  --data-binary '@-'

# Disallowed extension check (.exe)
'{"filename":"payload.exe","content_type":"application/octet-stream"}' | `
  curl.exe -k -s -i -X POST "$ALB_DNS/api/presigned-upload" `
  -H "Content-Type: application/json" `
  --data-binary '@-'
```

![Valid Upload Proof](./screenshots/upload%20request%20validation.png)
*Figure 4: Clean JSON `POST` payload piped to `curl.exe` returning `HTTP/1.1 200 OK` and a 300-second S3 pre-signed URL.*

![Disallowed File Extension Blocked](./screenshots/disallowed%20file%20extension.png)
*Figure 5: Server-side validation rejecting `payload.exe` with `HTTP/1.1 400 BAD REQUEST`.*

---

## Issue 6: `nc` (nmap-ncat) Not Pre-Installed on Minimal Amazon Linux 2023 AMI

### Symptom
Attempting to run `nc -zv $RDS_HOST 5432` inside the hardened Amazon Linux 2023 instance returned `sh: nc: command not found`.

### Root Cause
In accordance with the Operational Security & Hardening requirement (*"minimal packages installed"*), the Amazon Linux 2023 base AMI (`al2023-ami-2023.12.20261026.1-kernel-6.12-x86_64`) and `userdata.sh` only installed `python3-pip` and `postgresql15`, omitting network scanning utilities like `nmap-ncat`.

### Resolution
Used Bash's built-in `/dev/tcp/<host>/<port>` pseudo-device combined with `timeout 3` and the native PostgreSQL `pg_isready` utility to validate TCP port connectivity without installing unnecessary network utilities on the hardened production host.