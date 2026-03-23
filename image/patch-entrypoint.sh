#!/bin/sh
# patch-entrypoint.sh — patch cluster-entrypoint.sh to persist the SSH
# handshake secret across container restarts.
#
# Runs at Docker image build time. Uses only POSIX sh + awk, which are
# available in the base image. Fails loudly if the expected lines are not
# found so that upstream changes to the entrypoint don't silently break things.
set -eu

ENTRYPOINT="/usr/local/bin/cluster-entrypoint.sh"

# Verify both target lines are present before making any changes.
if ! grep -qF 'SSH_HANDSHAKE_SECRET:-$(head -c 32 /dev/urandom' "$ENTRYPOINT"; then
    echo "ERROR: handshake secret generation line not found in $ENTRYPOINT"
    echo "The upstream entrypoint may have changed — review patch-entrypoint.sh"
    exit 1
fi

if ! grep -qF 's|__SSH_HANDSHAKE_SECRET__|${SSH_HANDSHAKE_SECRET}|g' "$ENTRYPOINT"; then
    echo "ERROR: HelmChart injection line not found in $ENTRYPOINT"
    echo "The upstream entrypoint may have changed — review patch-entrypoint.sh"
    exit 1
fi

# Use awk to rewrite the file in one pass.
# Pattern 1: replace the urandom generation line with persist/load logic.
# Pattern 2: after the HelmChart injection line, insert the save-to-file lines.
awk '
/SSH_HANDSHAKE_SECRET:-\$\(head -c 32 \/dev\/urandom/ {
    print "SECRET_FILE=\"/var/lib/rancher/k3s/openshell-handshake-secret\""
    print "if [ -f \"$SECRET_FILE\" ]; then"
    print "    SSH_HANDSHAKE_SECRET=\"$(cat \"$SECRET_FILE\")\""
    print "    echo \"Loaded persisted SSH handshake secret\""
    print "else"
    print "    SSH_HANDSHAKE_SECRET=\"${SSH_HANDSHAKE_SECRET:-$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d '"'"' \n'"'"')}\""
    print "    echo \"Generated new SSH handshake secret\""
    print "fi"
    next
}
/s\|__SSH_HANDSHAKE_SECRET__\|\$\{SSH_HANDSHAKE_SECRET\}\|g/ {
    print
    print "    mkdir -p \"$(dirname \"$SECRET_FILE\")\""
    print "    printf '"'"'%s'"'"' \"$SSH_HANDSHAKE_SECRET\" > \"$SECRET_FILE\""
    print "    chmod 600 \"$SECRET_FILE\""
    next
}
{ print }
' "$ENTRYPOINT" > "${ENTRYPOINT}.patched"

mv "${ENTRYPOINT}.patched" "$ENTRYPOINT"
chmod +x "$ENTRYPOINT"

echo "Patched $ENTRYPOINT successfully."
grep -n 'SECRET_FILE\|Loaded\|Generated\|chmod 600' "$ENTRYPOINT"
