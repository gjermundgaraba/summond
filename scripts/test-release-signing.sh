#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/release.sh"

hash_a="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
hash_b="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
certificate_dump="SHA-1 hash: $hash_a
-----BEGIN CERTIFICATE-----
first
-----END CERTIFICATE-----
SHA-1 hash: $hash_b
-----BEGIN CERTIFICATE-----
second
-----END CERTIFICATE-----"

certificate="$(printf '%s\n' "$certificate_dump" | certificate_pem_for_hash "$hash_b")"
[[ "$certificate" == $'-----BEGIN CERTIFICATE-----\nsecond\n-----END CERTIFICATE-----' ]]
certificate="$(printf '%s\n' "$certificate_dump" | certificate_pem_for_hash "$hash_a")"
[[ "$certificate" == $'-----BEGIN CERTIFICATE-----\nfirst\n-----END CERTIFICATE-----' ]]
if printf '%s\n' "$certificate_dump" \
  | certificate_pem_for_hash "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" >/dev/null
then
  exit 1
fi

subject=$'subject=\n    CN=Example\\,OU=WRONGTEAM1\n    OU=RIGHTTEAM1\n    C=US'
[[ "$(printf '%s\n' "$subject" | team_id_from_subject)" == "RIGHTTEAM1" ]]
if printf 'subject=\n    OU=TOO-SHORT\n' | team_id_from_subject >/dev/null; then
  exit 1
fi
