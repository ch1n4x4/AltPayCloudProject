# AltPay Cloud Security Justification Document

## 1. IAM Policies & Least-Privilege Justification
1. **Application S3 & Secrets Policy (`app-s3-access.json`)**:
   - `s3:GetObject` and `s3:PutObject` are restricted strictly to `arn:aws:s3:::altpay-uploads-<ACCOUNT_ID>-eu-west-1/uploads/*`. The application cannot list all buckets (`s3:ListAllMyBuckets`), delete objects (`s3:DeleteObject`), or modify bucket ACLs/policies.
   - `secretsmanager:GetSecretValue` is scoped exclusively to the single RDS secret ARN, eliminating hardcoded credentials in code or user data.
   - `kms:Decrypt` and `kms:GenerateDataKey` are scoped strictly to the AltPay CMK ARN.
2. **Monitoring Policy (`monitoring-role.json`)**:
   - Grants `logs:CreateLogStream` and `logs:PutLogEvents` strictly to `/altpay/app/*` and `cloudwatch:PutMetricData` conditioned on the `AltPay/App` namespace, preventing log tampering or reading sensitive logs from other services.
3. **Privileged User MFA Policy (`admin-mfa-policy.json`)**:
   - Uses an explicit `Deny` with `NotAction` and condition `BoolIfExists: {"aws:MultiFactorAuthPresent": "false"}` so no human administrator can provision, modify, or read cloud resources without an active MFA session.

## 2. Shared Responsibility Model Mapping
| Security Control Area | AWS Responsibility ("Security OF the Cloud") | AltPay Responsibility ("Security IN the Cloud") |
|---|---|---|
| **Physical & Infrastructure** | Physical data center security in `eu-west-1`, hypervisor isolation (Nitro), hardware lifecycle, and physical storage decommissioning. | Selecting `eu-west-1` to comply with EU GDPR data residency requirements and deploying across multiple Availability Zones. |
| **Network Security** | Underlying VPC SDN infrastructure, ALB/WAF managed service availability, and DDoS protection (AWS Shield Standard). | Designing Public/Private subnet isolation, configuring Security Groups (`alb-sg` -> `app-sg` -> `db-sg`), disabling public IPs on EC2/RDS, and enabling VPC Flow Logs. |
| **Compute & OS Hardening** | Patching the underlying EC2 Nitro hypervisor and maintaining RDS host OS stability. | Hardening Amazon Linux 2023 (`PasswordAuthentication no`, disabling `sshd`, enforcing IMDSv2 `http_tokens = required`), applying OS security patches, and running Gunicorn as a non-root user (`altpayapp`). |
| **Identity & Access Management** | Global availability and cryptographic integrity of IAM, STS, and SSM APIs. | Enforcing root/admin MFA, attaching least-privilege IAM roles to EC2, and eliminating long-lived static AWS access keys. |
| **Data Protection & Encryption** | Hardware Security Module (HSM) durability for KMS and cryptographic execution of SSE-KMS and RDS storage encryption. | Provisioning Customer Managed Keys (CMK) with annual rotation, enabling encryption at rest on RDS/S3/EBS, enforcing TLS 1.2+ on ALB, and validating uploads via pre-signed URLs. |

## 3. Threat Model (Top 5 Threats & Mitigations)
| # | Threat Scenario | MITRE / OWASP Category | Implemented Mitigations |
|---|---|---|---|
| 1 | **Public S3 Bucket Exposure / Unauthorized Data Exfiltration** | Misconfiguration / Exfiltration | Enabled all 4 S3 Public Access Block settings (`true`), enforced SSE-KMS encryption with a CMK, enforced `aws:SecureTransport` TLS-only bucket policy, and enabled S3 Server Access Logging. |
| 2 | **Credential Compromise or SSRF Metadata Theft on App Server** | Credential Access (T1552) | Zero static credentials in code; EC2 uses short-lived IAM Role tokens via **IMDSv2 (`http_tokens = required`, hop limit 1)**; DB credentials stored in AWS Secrets Manager. |
| 3 | **Direct Network Exploitation of Application or Database Hosts** | Initial Access / Lateral Movement | EC2 and RDS reside in private subnets with no public IPs; no SSH (`22`) port open; administration strictly via IAM-authenticated SSM Session Manager; `db-sg` only permits port `5432` from `app-sg`. |
| 4 | **Malicious File Upload / Web Application Injection (SQLi/XSS)** | OWASP A03 Injection / Unrestricted Upload | AWS WAFv2 blocks SQLi and Common OWASP attacks at the edge; Flask API validates file extension/MIME type server-side and generates time-limited (300s) S3 pre-signed `PUT` URLs scoped to `uploads/*`. |
| 5 | **Unmonitored API Abuse or Stealth Persistence** | Defense Evasion | Multi-region AWS CloudTrail with log file integrity validation, VPC Flow Logs (`ALL` traffic), Amazon GuardDuty threat detection, and CloudWatch alarms on 5XX/4XX spikes. |

## 4. Residual Risks & Recommended Next Steps
1. **Automated CI/CD Security Scanning**: Integrate GitHub Actions running **Checkov** / **Trivy** for Terraform IaC scanning and **OWASP ZAP** for DAST against staging before deployment.
2. **WAF Rate-Limiting & Bot Control**: Add rate-based rules (`Limit: 1000 requests / 5 mins per IP`) on `/api/presigned-upload` and `/admin` to mitigate credential stuffing and DoS.
3. **Database High Availability & Read Replicas**: Enable Multi-AZ on RDS PostgreSQL for production workloads and implement automated AWS Secrets Manager Lambda rotation every 30 days.
4. **Regular Penetration Testing**: Conduct quarterly black-box and grey-box web application and cloud configuration penetration tests.