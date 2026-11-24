#!/bin/sh
# KG28 (spec.graphics.md): after switching a roaming client between
# networks, no image the client already holds may be sent again.
#
# Reads the roaming gateway's image log (subsystem dev.chr33s.swiftty.host,
# category images, process swiftmux-gateway; in-process test hosts are
# excluded) for the last N minutes. A resend is a blob for a digest the
# client listed in its Attach inventory (`cached=1`), or a second blob for
# the same digest within one attachment. A blob the client did not hold
# (after a reinstall or cache purge) is counted separately and is allowed.
#
# usage: kg28-image-resends.sh [minutes=30 | "YYYY-MM-DD HH:MM[:SS]"]
#   a start time reads from then on (for example the gateway's restart)
set -eu
arg=${1:-30}
case "$arg" in
  *-*|*:*) range="--start"; value="$arg" ;;
  *) range="--last"; value="${arg}m" ;;
esac
/usr/bin/log show --style compact "$range" "$value" \
    --predicate 'subsystem == "dev.chr33s.swiftty.host" AND category == "images" AND process == "swiftmux-gateway"' |
python3 -c '
import re, sys
attaches = blobs = aliases = uncached = 0
sent = set()
resends = []
for line in sys.stdin:
    m = re.search(r"\b(attach|blob|alias) epoch=(\d+)(?:.*?digest=([0-9a-f]+))?(?:.*?cached=(\d))?", line)
    if not m:
        continue
    kind, epoch, digest, cached = m.groups()
    if kind == "attach":
        attaches += 1
    elif kind == "alias":
        aliases += 1
    else:
        blobs += 1
        if cached == "1":
            resends.append((digest, epoch, "client held it"))
        elif (epoch, digest) in sent:
            resends.append((digest, epoch, "second blob in one attachment"))
        else:
            uncached += 1
        sent.add((epoch, digest))
print(f"attachments={attaches} blobs={blobs} aliases={aliases} "
      f"not_held={uncached} resends={len(resends)}")
for digest, epoch, why in resends:
    print(f"  resent {digest} in epoch {epoch}: {why}")
sys.exit(1 if resends else 0)
'
