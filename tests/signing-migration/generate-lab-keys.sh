#!/usr/bin/env bash
# Disposable, unencrypted lab keys. Never use these as production release keys.
set -euo pipefail
umask 077
lab=$(realpath "$1")
grep -Fxq 'signing-keys/' "$lab/.gitignore" || {
    printf 'Install the signing-keys/ ignore rule before generating keys.\n' >&2
    exit 1
}
keys=$lab/signing-keys/lab
test ! -L "$lab/signing-keys" && test ! -L "$keys"
install -d -m700 "$lab/signing-keys" "$keys"
for name in releasekey platform shared media networkstack sdk_sandbox bluetooth; do
    for suffix in pk8 x509.pem key.pem; do
        { test ! -e "$keys/$name.$suffix" && test ! -L "$keys/$name.$suffix"; } || {
            printf 'Refusing to overwrite an existing key or certificate: %s\n' "$name" >&2
            exit 1
        }
    done
done
for name in releasekey platform shared media networkstack sdk_sandbox bluetooth; do
    prefix=$keys/$name
    openssl req -new -x509 -newkey rsa:2048 -noenc -sha256 -days 30 \
        -subj "/O=NNS Signing Migration Lab/CN=$name" \
        -keyout "$prefix.key.pem" -out "$prefix.x509.pem"
    openssl pkcs8 -topk8 -nocrypt -outform DER \
        -in "$prefix.key.pem" -out "$prefix.pk8"
    openssl pkcs8 -inform DER -nocrypt -in "$prefix.pk8" -out /dev/null
    cmp -s <(openssl x509 -in "$prefix.x509.pem" -pubkey -noout) \
        <(openssl pkey -inform DER -in "$prefix.pk8" -pubout)
    rm "$prefix.key.pem"
    printf '%s\t' "$name"
    openssl x509 -in "$prefix.x509.pem" -outform DER | sha256sum | cut -d ' ' -f 1
done
