#!/bin/bash
# Polls CUPS tmp dir for invox PDFs and copies to user-readable spool
SRC="/private/var/spool/cups/tmp"
DST="/private/tmp/invox-spool"
mkdir -p "$DST"
chmod 777 "$DST"

while true; do
    for f in "$SRC"/invox_*.pdf; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        # Only copy if not already in destination
        if [ ! -f "$DST/$base" ]; then
            cp "$f" "$DST/$base" 2>/dev/null
            meta="${f%.pdf}.meta"
            [ -f "$meta" ] && cp "$meta" "$DST/${base%.pdf}.meta" 2>/dev/null
            chmod 644 "$DST/$base" "$DST/${base%.pdf}.meta" 2>/dev/null
        fi
    done
    sleep 0.2
done
