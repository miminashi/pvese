#!/bin/sh
set -eu
KEY="$(cd "$(dirname "$0")" && pwd)/idrac_rsa"
if [ -f "$KEY" ]; then
    echo "ssh/idrac_rsa already exists."
    exit 0
fi
echo "Generating iDRAC RSA key..."
ssh-keygen -t rsa -b 2048 -f "$KEY" -N ""
echo ""
echo "Key generated: $KEY"
echo "Register the public key (${KEY}.pub) in each iDRAC Web UI."
