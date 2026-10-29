#!/bin/bash
# Back up everything Notebook stores on this Mac before a migration.
# Run with Notebook closed:  scripts/backup-data.sh [destination folder]
# Nothing in the original data folders is changed.
set -euo pipefail

if [ -n "${NOTEBOOK_DATA_ROOT:-}" ]; then SOURCE="$NOTEBOOK_DATA_ROOT/userData"; else SOURCE="$HOME/Library/Application Support/Notebook"; fi
CONTENT="${NOTEBOOK_CONTENT_DIR:-$HOME/Notebook}"
DEST="${1:-$HOME/Documents/Notebook Backups/$(date +%Y-%m-%d-%H%M%S)}"

if [ ! -f "$SOURCE/notebook.sqlite" ]; then
    echo "No Notebook database at: $SOURCE/notebook.sqlite" >&2
    echo "Run this on the Mac where you use Notebook." >&2
    exit 1
fi
if [ -z "${NOTEBOOK_DATA_ROOT:-}" ] && pgrep -xq Notebook; then
    echo "Notebook is open. Quit it (Cmd+Q) and run this again." >&2
    exit 1
fi
if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
    echo "Destination is not empty: $DEST" >&2
    exit 1
fi
mkdir -p "$DEST/Application Support"

# SQLite's online backup includes changes still in the WAL file.
sqlite3 "$SOURCE/notebook.sqlite" ".backup '$DEST/Application Support/notebook.sqlite'"
check="$(sqlite3 "$DEST/Application Support/notebook.sqlite" 'PRAGMA integrity_check')"
if [ "$check" != "ok" ]; then
    echo "The backup copy failed its integrity check: $check" >&2
    exit 1
fi

# Everything else in the data folder: app lock, settings, agent key, legacy JSON and its backups.
for item in "$SOURCE"/* "$SOURCE"/.[!.]*; do
    [ -e "$item" ] || continue
    case "$(basename "$item")" in notebook.sqlite|notebook.sqlite-wal|notebook.sqlite-shm) continue ;; esac
    cp -Rp "$item" "$DEST/Application Support/"
done

if [ -d "$CONTENT" ]; then cp -Rp "$CONTENT" "$DEST/Markdown"; fi

db="$DEST/Application Support/notebook.sqlite"
{
    echo "Notebook backup"
    echo "Created: $(date)"
    echo "Computer: $(scutil --get ComputerName 2>/dev/null || hostname)"
    echo "From: $SOURCE"
    echo "Markdown from: $CONTENT $( [ -d "$CONTENT" ] && echo '(copied)' || echo '(not found)')"
    echo
    echo "Revisions by kind (kind | revisions | records ever | current, as the app lists them):"
    sqlite3 -separator ' | ' "$db" "SELECT kind, COUNT(*), COUNT(DISTINCT entity), (SELECT COUNT(*) FROM revisions h WHERE h.kind=r.kind AND h.payload IS NOT NULL AND NOT EXISTS (SELECT 1 FROM revisions c, json_each(c.parents) p WHERE c.kind=h.kind AND c.entity=h.entity AND p.value=h.id)) FROM revisions r GROUP BY kind ORDER BY kind"
    echo
    echo "Waiting to upload to iCloud: $(sqlite3 "$db" 'SELECT COUNT(*) FROM revisions WHERE uploaded=0')"
    echo "Paired with iCloud: $(sqlite3 "$db" "SELECT CASE WHEN EXISTS(SELECT 1 FROM meta WHERE key='notebook') THEN 'yes' ELSE 'no' END")"
    echo
    echo "Sizes:"
    du -sh "$DEST"/* | sed "s|$DEST/||"
} > "$DEST/BACKUP-SUMMARY.txt"

# Leave the copy as one self-contained file instead of database + WAL + SHM.
sqlite3 "$db" "PRAGMA journal_mode=DELETE" >/dev/null && rm -f "$db-shm"

cat "$DEST/BACKUP-SUMMARY.txt"
echo
echo "Backup saved to: $DEST"
