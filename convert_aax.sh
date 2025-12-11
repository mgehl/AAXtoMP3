#!/usr/bin/env bash

# AAX → Chaptered MP3 Converter
# Now safely creates the "chapters" folder automatically

set -euo pipefail

# ==================== CONFIGURATION ====================
BASE_DIR="/Users/mg/repos/audible-cli/audible_books"
AAXTOMP3="./AAXtoMP3"
# =======================================================

# Timestamped log file in script directory
LOG_DIR="$(dirname "$0")"
LOG_FILE="$LOG_DIR/convert_aax_$(date +%Y-%m-%d_%H-%M-%S).log"

# Log everything to terminal + file
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "============================================================"
echo "AAX to Chaptered MP3 Converter - Started at $(date)"
echo "Log file: $LOG_FILE"
echo "============================================================"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --all               Process all books (default)
  --test              Process only the first new book
  --book "Title"      Process only books whose folder contains this text (case-insensitive)
  --dry-run           Show what would run without converting
  --help              Show this help

Examples:
  $0
  $0 --test
  $0 --book "Dune"
  $0 --dry-run --book "Sapiens"
EOF
    exit 1
}

# Defaults
MODE="all"
BOOK_FILTER=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)      MODE="all" ; shift ;;
        --test)     MODE="test" ; shift ;;
        --book)
            [[ -z "${2:-}" ]] && echo "Error: --book requires an argument" && usage
            MODE="book"
            BOOK_FILTER="$2"
            shift 2
            ;;
        --dry-run)  DRY_RUN=true ; shift ;;
        --help)     usage ;;
        *) echo "Unknown option: $1" ; usage ;;
    esac
done

if [[ ! -f "$AAXTOMP3" ]]; then
    echo "ERROR: AAXtoMP3 not found at $AAXTOMP3"
    exit 1
fi

# Load authcode
AUTHCODE=""
for file in .authcode ~/.authcode; do
    [[ -r "$file" ]] && AUTHCODE=$(head -n1 "$file" | xargs) && break
done

if [[ -z "$AUTHCODE" ]]; then
    echo "WARNING: No authcode found"
    read -p "Continue without authcode? (y/N) " -n 1 -r REPLY
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo "Mode       : $MODE$( [[ -n "$BOOK_FILTER" ]] && echo " → \"$BOOK_FILTER\"" )"
[[ "$DRY_RUN" == true ]] && echo "DRY RUN    : Enabled"
echo "Base dir   : $BASE_DIR"
echo "Authcode   : $( [[ -n "$AUTHCODE" ]] && echo "found" || echo "missing" )"
echo "============================================================"

build_command() {
    local aax_file="$1"
    local aax_dir=$(dirname "$aax_file")
    local chapters_dir="${aax_dir}/chapters"

    # CRITICAL: Create the chapters directory if it doesn't exist
    mkdir -p "$chapters_dir"

    local cmd="$AAXTOMP3 --chaptered --level 5 --target_dir \"$chapters_dir\" --dir-naming-scheme ''"
    [[ -n "$AUTHCODE" ]] && cmd="$cmd --authcode $AUTHCODE"
    cmd="$cmd \"$aax_file\""
    echo "$cmd"
}

processed=0
matched=0

while IFS= read -r -d '' aax_file; do
    aax_dir=$(dirname "$aax_file")
    book_name=$(basename "$aax_dir")
    chapters_dir="${aax_dir}/chapters"

    # Book filter
    if [[ "$MODE" == "book" ]]; then
        if ! echo "$book_name" | grep -iq "$BOOK_FILTER"; then
            continue
        fi
        ((matched++))
    fi

    # Skip if already done
    if [[ -d "$chapters_dir" ]] && [[ -n "$(ls -A "$chapters_dir" 2>/dev/null)" ]]; then
        echo "[SKIP] Already converted: $book_name"
        continue
    fi

    echo "[START] $book_name"
    echo "        AAX  : $aax_file"
    echo "        Out  : $chapters_dir"

    if [[ "$DRY_RUN" == false ]]; then
        cmd=$(build_command "$aax_file")
        echo "        Running: $cmd"
        if eval "$cmd"; then
            echo "        SUCCESS: $book_name"
        else
            echo "        FAILED (code $?): $book_name"
        fi
    else
        echo "        [DRY RUN] Would convert → $chapters_dir"
    fi

    echo "------------------------------------------------------------"
    ((processed++))

    [[ "$MODE" == "test" ]] && break

done < <(find "$BASE_DIR" -type f -name "*.aax" -print0 | sort -z)

# Summary
echo "============================================================"
if (( processed == 0 )); then
    [[ "$MODE" == "book" ]] && echo "No books matched filter: \"$BOOK_FILTER\"" || echo "No new books to process."
else
    echo "All done! Successfully processed $processed book(s)"
    [[ "$MODE" == "book" ]] && echo "   (Matched $matched folder(s))"
fi
echo "Finished at $(date)"
echo "Log saved: $LOG_FILE"
echo "============================================================"