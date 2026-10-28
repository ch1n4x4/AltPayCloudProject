#!/bin/bash
# terraform/userdata.sh
set -euxo pipefail

# 1. Host Hardening: Disable SSH password auth and stop sshd (SSM Session Manager only)
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl stop sshd || true
systemctl disable sshd || true

# Apply OS security patches and install minimal dependencies
dnf update -y --security
dnf install -y python3-pip postgresql15
pip3 install flask gunicorn boto3 psycopg2-binary

# 2. Create Non-Root Service User for Application
useradd -r -s /sbin/nologin altpayapp || true
mkdir -p /opt/altpay
cat << 'EOF' > /opt/altpay/app.py
import os
import boto3
import json
from flask import Flask, request, jsonify, make_response

app = Flask(__name__)
REGION = "${aws_region}"
BUCKET_NAME = "${uploads_bucket}"
SECRET_ARN = "${db_secret_arn}"

s3_client = boto3.client("s3", region_name=REGION)
secrets_client = boto3.client("secretsmanager", region_name=REGION)

ALLOWED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg"}
MAX_CONTENT_LENGTH = 5 * 1024 * 1024  # 5 MB limit

@app.after_request
def apply_security_headers(response):
    response.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains; preload"
    response.headers["Content-Security-Policy"] = "default-src 'self'; frame-ancestors 'none'; object-src 'none';"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Set-Cookie"] = "altpay_session=secure_token; Secure; HttpOnly; SameSite=Strict"
    return response

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy", "service": "altpay-portal"}), 200

@app.route("/", methods=["GET"])
def portal_home():
    # Verify IAM Role + Secrets Manager integration (never exposing secret values)
    secret_meta = secrets_client.describe_secret(SecretId=SECRET_ARN)
    return jsonify({
        "portal": "AltPay Public Customer Portal",
        "region": REGION,
        "security": "TLS 1.2+, HSTS, CSP, SSE-KMS, IAM Role Active",
        "secret_managed_arn": secret_meta["ARN"]
    }), 200

@app.route("/api/presigned-upload", methods=["POST"])
def generate_presigned_upload():
    data = request.get_json(silent=True) or {}
    filename = os.path.basename(data.get("filename", ""))
    content_type = data.get("content_type", "")

    # Server-side validation of file extension and content type
    _, ext = os.path.splitext(filename.lower())
    if not filename or ext not in ALLOWED_EXTENSIONS:
        return jsonify({"error": "Invalid file type. Allowed: pdf, png, jpg"}), 400
    if content_type not in ["application/pdf", "image/png", "image/jpeg"]:
        return jsonify({"error": "Disallowed MIME content-type"}), 400

    object_key = f"uploads/{filename}"
    presigned_url = s3_client.generate_presigned_url(
        ClientMethod="put_object",
        Params={
            "Bucket": BUCKET_NAME,
            "Key": object_key,
            "ContentType": content_type,
            "ServerSideEncryption": "aws:kms"
        },
        ExpiresIn=300
    )
    return jsonify({
        "message": "Server-side validation passed. Use pre-signed URL within 300s.",
        "object_key": object_key,
        "upload_url": presigned_url
    }), 200

@app.route("/admin", methods=["GET"])
def admin_dashboard():
    auth_header = request.headers.get("X-AltPay-Admin-Token")
    if not auth_header:
        return jsonify({"error": "Unauthorized access to Admin Dashboard"}), 401
    return jsonify({"dashboard": "AltPay Internal Admin Portal"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
EOF

chown -R altpayapp:altpayapp /opt/altpay

cat << 'EOF' > /etc/systemd/system/altpay.service
[Unit]
Description=AltPay Gunicorn Service
After=network.target

[Service]
User=altpayapp
Group=altpayapp
WorkingDirectory=/opt/altpay
ExecStart=/usr/local/bin/gunicorn --workers 2 --bind 0.0.0.0:8000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now altpay.service