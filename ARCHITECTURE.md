# AltPay Cloud Architecture & Security Design Specification

![Environment](https://img.shields.io/badge/AWS_Region-eu--west--1_(Ireland)-blue?style=flat-square)
![VPC](https://img.shields.io/badge/VPC_CIDR-10.0.0.0%2F16-success?style=flat-square)
![Encryption](https://img.shields.io/badge/Encryption-KMS_CMK_%2B_TLS_1.2%2B-orange?style=flat-square)

> **Document Purpose:** This document provides a comprehensive architectural breakdown of the AltPay three-tier cloud environment deployed in `eu-west-1` (Europe — Ireland). It details the network topology, subnet segmentation, security group rules, IAM role data flows, cryptographic boundaries, and exact resource identifiers/ARNs provisioned via Terraform.

---

## Table of Contents
- [1. High-Level Architectural Topology](#1-high-level-architectural-topology)
- [2. Deployed Resource Inventory & ARN Reference](#2-deployed-resource-inventory--arn-reference)
- [3. Network Segmentation & Subnet Design](#3-network-segmentation--subnet-design)
- [4. Security Group Matrix (Least-Privilege Firewall Rules)](#4-security-group-matrix-least-privilege-firewall-rules)
- [5. Identity, Access Management (IAM) & Zero-SSH Flow](#5-identity-access-management-iam--zero-ssh-flow)
- [6. Cryptographic Architecture (Data in Transit & At Rest)](#6-cryptographic-architecture-data-in-transit--at-rest)
- [7. Observability, Audit Logging & Edge Defense](#7-observability-audit-logging--edge-defense)

---

## 1. High-Level Architectural Topology

AltPay's cloud infrastructure follows a strict **defense-in-depth, three-tier architecture** designed to process customer portal requests and file uploads without exposing compute or data stores to the public internet.

```mermaid
flowchart TD
    subgraph External ["Untrusted Internet Zone"]
        Client["Customer / API Client"]
        Attacker["Malicious Actor (SQLi / XSS / Port Scan)"]
    end

    subgraph Perimeter ["Perimeter & Edge Security Layer"]
        WAF["AWS WAFv2 Web ACL<br/>arn:aws:wafv2:eu-west-1:865266771761:regional/webacl/altpay-waf-acl/69039a5c-1355-4a54-a1ee-a9575573af15<br/>(OWASP CommonRuleSet + SQLiRuleSet)"]
        ALB["Public Application Load Balancer (altpay-public-alb)<br/>DNS: altpay-public-alb-90886461.eu-west-1.elb.amazonaws.com<br/>SG: sg-024acb052230a19fd | TLS Policy: ELBSecurityPolicy-TLS13-1-2-2021-06"]
    end

    subgraph VPC ["altpay-vpc (vpc-0b1ccba5d30aaa613 | 10.0.0.0/16)"]
        subgraph PublicTier ["Public Tier (eu-west-1a: 10.0.1.0/24 | eu-west-1b: 10.0.2.0/24)"]
            IGW["Internet Gateway<br/>(igw-07ee60e796ba3c481)"]
            NAT["NAT Gateway<br/>(nat-096302182dbfe63c9 | EIP: 46.51.175.171)"]
        end

        subgraph AppTier ["Private Application Tier (eu-west-1a: 10.0.11.0/24 | eu-west-1b: 10.0.12.0/24)"]
            EC2["Hardened App Server (altpay-private-app-server)<br/>ID: i-00745caf3b19355fd | Private IP: 10.0.11.215 | Public IP: None<br/>SG: sg-067c31c5212515915 | Role: altpay-ec2-app-role | IMDSv2 Required"]
        end

        subgraph DBTier ["Private Database Tier (eu-west-1a: 10.0.21.0/24 | eu-west-1b: 10.0.22.0/24)"]
            RDS[("RDS PostgreSQL 16.13 (altpay-postgres-db)<br/>Endpoint: altpay-postgres-db.czek08ukwcnb.eu-west-1.rds.amazonaws.com:5432<br/>Private IP: 10.0.21.253 | Publicly Accessible: No<br/>SG: sg-05ae81e2cdde75d94 | KMS Encrypted")]
        end

        subgraph IsolatedTier ["Isolated Sales Subnet (eu-west-1a: 10.0.99.0/24)"]
            SalesSub["subnet-07ff6b15e7cbdc4af<br/>(Zero Route / Blocked by db-sg)"]
        end

        S3VPCE["S3 Gateway VPC Endpoint<br/>(vpce-0ea9433805dc0e6a5)"]
    end

    subgraph AWSBackbone ["AWS Managed Security, Storage & Logging Services"]
        KMS["KMS Customer Managed Key (alias/altpay-cmk)<br/>arn:aws:kms:eu-west-1:865266771761:key/d7001bef-6679-4eb1-b029-89f51ff43ed5"]
        Secrets["AWS Secrets Manager<br/>arn:aws:secretsmanager:eu-west-1:865266771761:secret:altpay/prod/rds-credentials-v1-VND5ox"]
        S3Uploads[("S3 Uploads Bucket<br/>altpay-uploads-865266771761-eu-west-1<br/>(SSE-KMS + Public Access Blocked)")]
        S3AccessLogs[("S3 Server Access Logs Bucket<br/>altpay-access-logs-865266771761-eu-west-1")]
        CloudTrail["AWS CloudTrail (altpay-audit-trail)<br/>Bucket: altpay-cloudtrail-865266771761-eu-west-1"]
        CWLogs["CloudWatch Log Groups & Alarm<br/>/altpay/vpc/flow-logs | /altpay/app/portal<br/>Alarm: altpay-alb-high-5xx-alarm"]
    end

    Client -->|HTTPS :443| WAF
    Attacker -.->|Blocked at Edge| WAF
    WAF --> IGW --> ALB
    ALB -->|HTTP :8000| EC2
    EC2 -->|TCP :5432| RDS
    SalesSub -.->|x REJECTED x| RDS
    EC2 -->|Private Route| S3VPCE --> S3Uploads
    EC2 -->|STS AssumeRole + DescribeSecret| Secrets
    S3Uploads -.->|Access Logs| S3AccessLogs
    VPC -.->|VPC Flow Logs (fl-0d5c6a5171058e0bd)| CWLogs
    KMS -.->|SSE-KMS / At-Rest Encryption| RDS & S3Uploads & Secrets & CloudTrail & CWLogs
```

---

## 2. Deployed Resource Inventory & ARN Reference

Every resource in the table below was provisioned in AWS Account `865266771761` (`eu-west-1`) via Terraform:

| Tier / Category | Resource Name | Resource ID / ARN / Endpoint |
| :--- | :--- | :--- |
| **VPC** | `altpay-vpc` | `vpc-0b1ccba5d30aaa613` (`arn:aws:ec2:eu-west-1:865266771761:vpc/vpc-0b1ccba5d30aaa613`) |
| **Internet Gateway** | `altpay-igw` | `igw-07ee60e796ba3c481` |
| **NAT Gateway** | `altpay-nat-gw` | `nat-096302182dbfe63c9` (Elastic IP: `46.51.175.171` / `eipalloc-06bafc271f7fc7368`) |
| **S3 VPC Endpoint** | `altpay-s3-endpoint` | `vpce-0ea9433805dc0e6a5` (`com.amazonaws.eu-west-1.s3` — Gateway Type) |
| **Public ALB** | `altpay-public-alb` | `arn:aws:elasticloadbalancing:eu-west-1:865266771761:loadbalancer/app/altpay-public-alb/03d61c31efaf6e6f`<br/>DNS: `altpay-public-alb-90886461.eu-west-1.elb.amazonaws.com` |
| **ACM Certificate** | `altpay-acm-cert` | `arn:aws:acm:eu-west-1:865266771761:certificate/de768941-af4e-42e0-987a-0b6233b9c178` |
| **AWS WAFv2 ACL** | `altpay-waf-acl` | `arn:aws:wafv2:eu-west-1:865266771761:regional/webacl/altpay-waf-acl/69039a5c-1355-4a54-a1ee-a9575573af15` |
| **Private App EC2** | `altpay-private-app-server` | `i-00745caf3b19355fd` (`arn:aws:ec2:eu-west-1:865266771761:instance/i-00745caf3b19355fd`)<br/>Private IP: `10.0.11.215` \| Public IP: `None` \| Encrypted Root Volume: `vol-05e6b5e9c6f277fd2` |
| **EC2 IAM Role** | `altpay-ec2-app-role` | `arn:aws:iam::865266771761:role/altpay-ec2-app-role` (Instance Profile: `altpay-ec2-instance-profile`) |
| **Custom IAM Policies** | `altpay-app-s3-access`<br/>`altpay-monitoring-policy`<br/>`altpay-enforce-admin-mfa` | `arn:aws:iam::865266771761:policy/altpay-app-s3-access`<br/>`arn:aws:iam::865266771761:policy/altpay-monitoring-policy`<br/>`arn:aws:iam::865266771761:policy/altpay-enforce-admin-mfa` |
| **Private RDS DB** | `altpay-postgres-db` | `arn:aws:rds:eu-west-1:865266771761:db:altpay-postgres-db` (Resource ID: `db-URYWHLD57LSNJ2NMTORQKTRA4M`)<br/>Endpoint: `altpay-postgres-db.czek08ukwcnb.eu-west-1.rds.amazonaws.com:5432` |
| **S3 Uploads Bucket** | `altpay-uploads-...` | `arn:aws:s3:::altpay-uploads-865266771761-eu-west-1` |
| **S3 Access Logs** | `altpay-access-logs-...` | `arn:aws:s3:::altpay-access-logs-865266771761-eu-west-1` |
| **KMS CMK** | `altpay-cmk` (`alias/altpay-cmk`) | `arn:aws:kms:eu-west-1:865266771761:key/d7001bef-6679-4eb1-b029-89f51ff43ed5` |
| **Secrets Manager** | `altpay/prod/rds-credentials-v1` | `arn:aws:secretsmanager:eu-west-1:865266771761:secret:altpay/prod/rds-credentials-v1-VND5ox` |
| **CloudTrail** | `altpay-audit-trail` | `arn:aws:cloudtrail:eu-west-1:865266771761:trail/altpay-audit-trail`<br/>S3 Bucket: `arn:aws:s3:::altpay-cloudtrail-865266771761-eu-west-1` |
| **VPC Flow Logs** | `altpay-vpc-flow-logs` | `fl-0d5c6a5171058e0bd` → Log Group: `arn:aws:logs:eu-west-1:865266771761:log-group:/altpay/vpc/flow-logs` |
| **CloudWatch Alarm** | `altpay-alb-high-5xx-alarm` | `arn:aws:cloudwatch:eu-west-1:865266771761:alarm:altpay-alb-high-5xx-alarm` |

---

## 3. Network Segmentation & Subnet Design

The VPC (`10.0.0.0/16`) is partitioned across two Availability Zones (`eu-west-1a` and `eu-west-1b`) into four distinct functional tiers:

| Subnet Name | Subnet ID | Availability Zone | CIDR Block | Auto-Assign Public IP | Route Table & Connectivity |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `altpay-public-subnet-a` | `subnet-028377951cae0ed33` | `eu-west-1a` | `10.0.1.0/24` | `true` | `altpay-public-rt` (`rtb-029ad56d2cde66dec`) → Internet Gateway (`igw-07ee60e796ba3c481`) |
| `altpay-public-subnet-b` | `subnet-0eedd9b6bbd5feba6` | `eu-west-1b` | `10.0.2.0/24` | `true` | `altpay-public-rt` (`rtb-029ad56d2cde66dec`) → Internet Gateway (`igw-07ee60e796ba3c481`) |
| `altpay-private-app-a` | `subnet-07ecf01028c239641` | `eu-west-1a` | `10.0.11.0/24` | `false` | `altpay-private-rt` (`rtb-0e9eda3a3894b254f`) → NAT Gateway (`nat-096302182dbfe63c9`) + S3 Gateway Endpoint (`vpce-0ea9433805dc0e6a5`) |
| `altpay-private-app-b` | `subnet-0931a5eb2b99330e3` | `eu-west-1b` | `10.0.12.0/24` | `false` | `altpay-private-rt` (`rtb-0e9eda3a3894b254f`) → NAT Gateway + S3 Gateway Endpoint |
| `altpay-private-db-a` | `subnet-041a71d13748c6e9a` | `eu-west-1a` | `10.0.21.0/24` | `false` | Local VPC routing only (`altpay-db-subnet-group` — No IGW/NAT route) |
| `altpay-private-db-b` | `subnet-00f3a9e8f97e1250a` | `eu-west-1b` | `10.0.22.0/24` | `false` | Local VPC routing only (`altpay-db-subnet-group` — No IGW/NAT route) |
| `altpay-sales-subnet` | `subnet-07ff6b15e7cbdc4af` | `eu-west-1a` | `10.0.99.0/24` | `false` | Isolated non-privileged segment (blocked from reaching `altpay-db-sg`) |

---

## 4. Security Group Matrix (Least-Privilege Firewall Rules)

All Security Groups follow a strict default-deny posture. No host permits inbound SSH (`22`) or RDP (`3389`), and internal tiers reference upstream Security Group IDs rather than broad IP ranges.

| Security Group Name & ID | Direction | Protocol & Port | Source / Destination | Security Justification |
| :--- | :--- | :--- | :--- | :--- |
| **`altpay-alb-sg`**<br/>`sg-024acb052230a19fd` | **Inbound**<br/>**Inbound**<br/>**Outbound** | `TCP 443`<br/>`TCP 80`<br/>`TCP 8000` | `0.0.0.0/0`<br/>`0.0.0.0/0`<br/>`sg-067c31c5212515915` (`altpay-app-sg`) | Accepts customer HTTPS requests and HTTP port 80 strictly to issue an immediate `301` redirect to HTTPS. Egress is locked solely to the App SG on port `8000`. |
| **`altpay-app-sg`**<br/>`sg-067c31c5212515915` | **Inbound**<br/>**Outbound**<br/>**Outbound** | `TCP 8000`<br/>`TCP 5432`<br/>`TCP 443` | `sg-024acb052230a19fd` (`altpay-alb-sg`)<br/>`sg-05ae81e2cdde75d94` (`altpay-db-sg`)<br/>`0.0.0.0/0` | Prevents direct access to Gunicorn/Flask except through the ALB/WAF. Permits outbound PostgreSQL (`5432`) strictly to the DB SG and HTTPS (`443`) for SSM Session Manager, Secrets Manager, and S3. |
| **`altpay-db-sg`**<br/>`sg-05ae81e2cdde75d94` | **Inbound**<br/>**Outbound** | `TCP 5432`<br/>`None` | `sg-067c31c5212515915` (`altpay-app-sg`)<br/>`None` (0 Egress Rules) | Ensures only the private application server can query PostgreSQL. Blocks lateral movement from public subnets or the isolated `Sales` subnet (`10.0.99.0/24`). |

![Security Group Rules in Console](./screenshots/security%20group.png)
*Figure 1: Security Group inventory showing `altpay-alb-sg`, `altpay-app-sg`, and `altpay-db-sg`.*

![App Security Group Rule Details](./screenshots/altpay%20app%20sg%20details.png)
*Figure 2: Detailed inbound (`TCP 8000` from `sg-024acb052230a19fd`) and outbound (`TCP 443` and `TCP 5432` to `sg-05ae81e2cdde75d94`) rules on `altpay-app-sg`.*

---

## 5. Identity, Access Management (IAM) & Zero-SSH Flow

### Compute Identity (`altpay-ec2-app-role`)
The private EC2 instance (`i-00745caf3b19355fd`) authenticates to AWS APIs using temporary STS credentials provisioned via Instance Profile `altpay-ec2-instance-profile` (`arn:aws:iam::865266771761:instance-profile/altpay-ec2-instance-profile`).
- **IMDSv2 Enforcement:** Configured with `http_tokens = "required"` and `http_put_response_hop_limit = 1`, neutralizing Server-Side Request Forgery (SSRF) credential theft against `169.254.169.254`.
- **Prefix-Scoped S3 Access (`altpay-app-s3-access`):** Grants `s3:GetObject` and `s3:PutObject` exclusively on `arn:aws:s3:::altpay-uploads-865266771761-eu-west-1/uploads/*`.
- **Resource-Scoped Secret Retrieval:** Grants `secretsmanager:GetSecretValue` and `secretsmanager:DescribeSecret` exclusively on `arn:aws:secretsmanager:eu-west-1:865266771761:secret:altpay/prod/rds-credentials-v1-VND5ox`.
- **Namespace-Scoped Monitoring (`altpay-monitoring-policy`):** Restricts log stream creation and event ingestion to `arn:aws:logs:eu-west-1:865266771761:log-group:/altpay/app/portal:*` and metric publishing to the `AltPay/App` namespace.

![IAM Role & Attached Policies](./screenshots/iam%20role.png)
*Figure 3: `altpay-ec2-app-role` configuration showing the trust relationship and attached least-privilege policies.*

---

## 6. Cryptographic Architecture (Data in Transit & At Rest)

### Encryption at Rest (AWS KMS Customer Managed Key)
All persistent data stores and logs are encrypted using a dedicated symmetric KMS Customer Managed Key (`alias/altpay-cmk`, ARN: `arn:aws:kms:eu-west-1:865266771761:key/d7001bef-6679-4eb1-b029-89f51ff43ed5`) with `enable_key_rotation = true` (365-day automatic rotation):
1. **Amazon S3 (`altpay-uploads-865266771761-eu-west-1`):** Default `aws:kms` server-side encryption (SSE-KMS) with S3 Bucket Keys enabled.
2. **Amazon RDS (`altpay-postgres-db`):** `gp3` storage volume and automated snapshots encrypted with `altpay-cmk`.
3. **Amazon EC2 (`altpay-private-app-server`):** 8 GB `gp3` root EBS volume (`vol-05e6b5e9c6f277fd2`) encrypted with `altpay-cmk`.
4. **AWS Secrets Manager (`altpay/prod/rds-credentials-v1`):** Secret payload encrypted under `altpay-cmk`.
5. **AWS CloudTrail & CloudWatch Logs:** Trail objects in `altpay-cloudtrail-865266771761-eu-west-1` and log groups `/altpay/app/portal` and `/altpay/vpc/flow-logs` are encrypted using `altpay-cmk`.

### Encryption in Transit & Application Transport Hardening
1. **Edge TLS 1.2 / 1.3 Termination:** The ALB HTTPS listener (`port 443`) enforces `ELBSecurityPolicy-TLS13-1-2-2021-06` and redirects all plaintext HTTP (`port 80`) requests via `HTTP_301`.
2. **S3 Secure Transport Policy:** The bucket policy (`EnforceTLSRequestsOnly`) explicitly denies `s3:*` actions whenever `"aws:SecureTransport": "false"`.
3. **Security Response Headers:** Every Flask application response injects:
   - `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`
   - `Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; object-src 'none';`
   - `X-Frame-Options: DENY`
   - `X-Content-Type-Options: nosniff`
   - `Referrer-Policy: strict-origin-when-cross-origin`
   - `Set-Cookie: altpay_session=secure_token; Secure; HttpOnly; SameSite=Strict`

---

## 7. Observability, Audit Logging & Edge Defense

1. **AWS WAFv2 (`altpay-waf-acl`):** Attached directly to `altpay-public-alb`, inspecting incoming requests against `AWSManagedRulesCommonRuleSet` (Priority 1) and `AWSManagedRulesSQLiRuleSet` (Priority 2) with CloudWatch sampled requests enabled.
2. **AWS CloudTrail (`altpay-audit-trail`):** Multi-region trail with `enable_log_file_validation = true` (SHA-256 digest verification) and global service events enabled.
3. **VPC Flow Logs (`fl-0d5c6a5171058e0bd`):** Captures `ALL` (`ACCEPT` and `REJECT`) network traffic across `vpc-0b1ccba5d30aaa613` and streams records to `/altpay/vpc/flow-logs`.
4. **CloudWatch Metric Alarm (`altpay-alb-high-5xx-alarm`):** Evaluates `HTTPCode_Target_5XX_Count` over 60-second periods and triggers when `Sum >= 5`.

![CloudWatch Log Groups Overview](./screenshots/cloudwatch%20log%20groups.png)
*Figure 4: CloudWatch Log Groups `/altpay/app/portal` and `/altpay/vpc/flow-logs` with 14-day retention and KMS encryption.*