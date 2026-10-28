# AltPay Infrastructure Setup, Deployment & Validation Guide

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5.0-844FBA?style=flat-square)
![AWS CLI](https://img.shields.io/badge/AWS_CLI-v2-232F3E?style=flat-square)
![Shell](https://img.shields.io/badge/Shell-PowerShell_%26_Bash-5391FE?style=flat-square)

> **Document Purpose:** This guide provides end-to-end instructions to reproduce, validate, and tear down the AltPay secure three-tier cloud infrastructure on AWS (`eu-west-1`) using Terraform and Windows PowerShell.

---

## Table of Contents
- [1. Prerequisites & Tooling Setup](#1-prerequisites--tooling-setup)
- [2. Repository Structure](#2-repository-structure)
- [3. Pre-Deployment Account Security & Cost Controls](#3-pre-deployment-account-security--cost-controls)
- [4. Step-by-Step Terraform Deployment](#4-step-by-step-terraform-deployment)
- [5. Exporting KMS & Secrets Manager Metadata](#5-exporting-kms--secrets-manager-metadata)
- [6. Security Validation & Proof Commands](#6-security-validation--proof-commands)
- [7. Teardown & Cost-Control Cleanup](#7-teardown--cost-control-cleanup)

---

## 1. Prerequisites & Tooling Setup

Ensure the following tools are installed on your workstation prior to deployment:

1. **AWS Account (Free-Tier Eligible):** Configured in region `eu-west-1` (Europe — Ireland).
2. **Terraform CLI (`>= 1.5.0`):** Verify with `terraform -version`.
3. **AWS CLI v2:** Configured with an IAM administrative user/role (`aws configure`).
4. **AWS Session Manager Plugin for Windows:** Required to establish interactive shell sessions to the private EC2 instance without SSH or a public IP.

### Installing the AWS Session Manager Plugin (PowerShell)
```powershell
Invoke-WebRequest `
  -Uri "[https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe](https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe)" `
  -OutFile "$env:TEMP\SessionManagerPluginSetup.exe"

Start-Process -FilePath "$env:TEMP\SessionManagerPluginSetup.exe" -ArgumentList "/quiet" -Wait

# Refresh PATH in current PowerShell session and verify installation
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
session-manager-plugin
```

![Install AWS Session Manager Plugin](./screenshots/install%20aws%20session%20manager%20plugin.png)
*Figure 1: Installing and verifying the AWS Session Manager Plugin in Windows PowerShell.*

---

## 2. Repository Structure

```text
AltPayCloudProject/
├── README.md                              # Main project case study & overview
├── architecture.md                        # Detailed network, IAM, and cryptographic design
├── setup.md                               # Step-by-step reproduction and validation guide
├── troubleshooting.md                     # Operational runbook & issue resolutions
├── Security_Justification_Document.md     # Shared Responsibility & Threat Model report
├── Cleanup_Instructions.md                # Teardown commands to prevent AWS charges
├── iam-policies/                          # Standalone least-privilege IAM policy JSONs
│   ├── admin-mfa-policy.json
│   ├── app-s3-access.json
│   └── monitoring-role.json
├── kms-and-secrets/                       # Non-sensitive KMS & Secrets Manager metadata
│   ├── kms-key-policy.json
│   └── secret-metadata.json
├── screenshots/                           # Console & CLI verification evidence
└── terraform/                             # Complete Terraform IaC configuration
    ├── provider.tf
    ├── variables.tf
    ├── network.tf
    ├── security_groups.tf
    ├── kms_secrets.tf
    ├── iam.tf
    ├── s3.tf
    ├── rds.tf
    ├── ec2_app.tf
    ├── alb_waf.tf
    ├── logging_monitoring.tf
    ├── outputs.tf
    └── userdata.sh
```

---

## 3. Pre-Deployment Account Security & Cost Controls

1. **Root Account Lockdown:** Log in to the AWS Console, navigate to **IAM > Dashboard**, confirm **MFA is activated** on the root account, and verify zero active root access keys exist.
2. **Privileged User MFA:** Attach `iam-policies/admin-mfa-policy.json` (`altpay-enforce-admin-mfa`) to administrative console groups so all actions require MFA (`"aws:MultiFactorAuthPresent": "true"`).
3. **Billing & Free-Tier Alerts:** In **AWS Billing and Cost Management > Billing Preferences**, enable **Receive AWS Free Tier alerts** and configure a **$1.00 Zero-Spend Budget** alert.
   - *Cost Note:* While `t3.micro` EC2, `db.t3.micro` Single-AZ RDS, S3, and CloudTrail qualify for the AWS Free Tier, the **NAT Gateway**, **Application Load Balancer**, **KMS CMK**, and **AWS WAFv2 Web ACL** incur small hourly pro-rated charges (~$0.05–$0.08/hour combined). Destroying the environment immediately after validation keeps total deployment cost under **$0.50**.

---

## 4. Step-by-Step Terraform Deployment

Open Windows PowerShell, navigate to the `terraform/` directory, and initialize, validate, plan, and apply the infrastructure:

```powershell
Set-Location -Path .\terraform

# 1. Initialize Terraform providers (hashicorp/aws v6.70.0, random, tls)
terraform init

# 2. Validate HCL syntax and resource references
terraform validate

# 3. Generate an execution plan (49 resources to create)
terraform plan -out="tfplan"

# 4. Provision the infrastructure in eu-west-1
terraform apply "tfplan"
```

![Terraform Apply Execution](./screenshots/terraform%20apply.png)
*Figure 2: `terraform apply "tfplan"` completing with 49 resources provisioned in `eu-west-1`.*

### Expected Terraform Outputs
```text
alb_https_endpoint  = "[https://altpay-public-alb-90886461.eu-west-1.elb.amazonaws.com](https://altpay-public-alb-90886461.eu-west-1.elb.amazonaws.com)"
app_instance_id     = "i-00745caf3b19355fd"
db_secret_arn       = "arn:aws:secretsmanager:eu-west-1:865266771761:secret:altpay/prod/rds-credentials-v1-VND5ox"
kms_key_arn         = "arn:aws:kms:eu-west-1:865266771761:key/d7001bef-6679-4eb1-b029-89f51ff43ed5"
rds_endpoint        = "altpay-postgres-db.czek08ukwcnb.eu-west-1.rds.amazonaws.com:5432"
uploads_bucket_name = "altpay-uploads-865266771761-eu-west-1"
```

---

## 5. Exporting KMS & Secrets Manager Metadata

Export the non-sensitive KMS key policy and Secrets Manager entry metadata to `kms-and-secrets/` for audit verification:

```powershell
New-Item -ItemType Directory -Force -Path ..\kms-and-secrets | Out-Null

$KMS_ARN = terraform output -raw kms_key_arn
$SECRET_ARN = terraform output -raw db_secret_arn

aws kms get-key-policy `
  --key-id "$KMS_ARN" `
  --policy-name default `
  --output json | Out-File -FilePath ..\kms-and-secrets\kms-key-policy.json -Encoding utf8

aws secretsmanager describe-secret `
  --secret-id "$SECRET_ARN" `
  --output json | Out-File -FilePath ..\kms-and-secrets\secret-metadata.json -Encoding utf8
```

---

## 6. Security Validation & Proof Commands

### Proof 1: HTTPS Redirect, Security Response Headers & Upload Validation

```powershell
$ALB_DNS = terraform output -raw alb_https_endpoint
$ALB_HTTP = $ALB_DNS -replace '^https://', 'http://'

# 1a. Verify HTTP (Port 80) -> HTTPS (Port 443) 301 Permanent Redirect
curl.exe -I "$ALB_HTTP/"

# 1b. Verify HTTPS 200 OK + HSTS, CSP, X-Frame-Options, X-Content-Type-Options, Secure Cookie
curl.exe -k -i "$ALB_DNS/"

# 1c. Valid upload request (.pdf) -> Returns 200 OK + 300s SSE-KMS Pre-Signed S3 PUT URL
'{"filename":"invoice.pdf","content_type":"application/pdf"}' | `
  curl.exe -k -s -i -X POST "$ALB_DNS/api/presigned-upload" `
  -H "Content-Type: application/json" `
  --data-binary '@-'

# 1d. Disallowed file extension (.exe) -> Blocked server-side with 400 Bad Request
'{"filename":"payload.exe","content_type":"application/octet-stream"}' | `
  curl.exe -k -s -i -X POST "$ALB_DNS/api/presigned-upload" `
  -H "Content-Type: application/json" `
  --data-binary '@-'

# 1e. Unauthenticated Admin Portal request -> Blocked with 401 Unauthorized
curl.exe -k -i "$ALB_DNS/admin"
```

![HTTPS Endpoint Validation Output](./screenshots/HTTPS%20Endpoint%20validation.png)
*Figure 3: Verifying HTTP 301 redirect and HTTPS 200 OK security headers from `altpay-public-alb`.*

### Proof 2: Private Host Access via SSM & Network Isolation (`5432` vs `22`)

Start an interactive AWS Systems Manager Session Manager session to the private application server (`i-00745caf3b19355fd`):

```powershell
$APP_ID = terraform output -raw app_instance_id
$RDS_ENDPOINT = terraform output -raw rds_endpoint
$RDS_HOST = ($RDS_ENDPOINT -split ':')[0]

Write-Host "RDS Hostname to test inside SSM: $RDS_HOST" -ForegroundColor Cyan
aws ssm start-session --target "$APP_ID"
```

Inside the remote Linux SSM shell (`sh-5.2$`), export `RDS_HOST` and test allowed vs. disallowed ports:

```bash
export RDS_HOST="altpay-postgres-db.czek08ukwcnb.eu-west-1.rds.amazonaws.com"
getent hosts "$RDS_HOST"

# 1. Allowed Flow: App Tier -> RDS on PostgreSQL port 5432 (Succeeds)
timeout 3 bash -c "</dev/tcp/$RDS_HOST/5432" && echo "SUCCESS: Connected to RDS on port 5432"
pg_isready -h "$RDS_HOST" -p 5432

# 2. Disallowed Flow: App Tier -> RDS on SSH port 22 (Blocked by altpay-db-sg & logged as REJECT)
timeout 3 bash -c "</dev/tcp/$RDS_HOST/22" && echo "UNEXPECTED SUCCESS" || echo "BLOCKED: Connection to RDS on port 22 timed out / rejected as expected"

exit
```

![SSM Port Verification](./screenshots/verify%20allowed%20and%20disallowed%20ports.png)
*Figure 4: SSM session output confirming PostgreSQL port 5432 is reachable from the App Tier while port 22 is blocked.*

Back in PowerShell, query the `REJECT` entries recorded by VPC Flow Logs in CloudWatch Logs:

```powershell
aws logs filter-log-events `
  --log-group-name "/altpay/vpc/flow-logs" `
  --filter-pattern "REJECT" `
  --max-items 5 `
  --output json
```

### Proof 3: CloudTrail Audit Log Verification (`AssumeRole` & `DescribeSecret`)

```powershell
# Verify sts:AssumeRole events performed by altpay-ec2-app-role
aws cloudtrail lookup-events `
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole `
  --max-results 3 `
  --output json

# Verify Secrets Manager access by the EC2 instance role
aws cloudtrail lookup-events `
  --lookup-attributes AttributeKey=EventName,AttributeValue=DescribeSecret `
  --max-results 3 `
  --output json
```

---

## 7. Teardown & Cost-Control Cleanup

Once all validation evidence and screenshots have been captured, destroy all Terraform-managed resources to stop hourly billing on the NAT Gateway, ALB, and WAFv2 Web ACL:

```powershell
Set-Location -Path .\terraform
terraform destroy -auto-approve

# Confirm zero lingering billable resources in eu-west-1
aws ec2 describe-nat-gateways --region eu-west-1 --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]' --output table
aws elbv2 describe-load-balancers --region eu-west-1 --query 'LoadBalancers[*].[LoadBalancerName,State.Code]' --output table
aws rds describe-db-instances --region eu-west-1 --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus]' --output table
aws ec2 describe-addresses --region eu-west-1 --query 'Addresses[*].[PublicIp,AllocationId]' --output table
```

![Terraform Destroy Output](./screenshots/terraform%20destroy.png)
*Figure 5: `terraform destroy -auto-approve` cleanly deleting all 49 resources (`Destroy complete! Resources: 49 destroyed.`).*