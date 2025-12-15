#!/usr/bin/env bash

# Multi-Part AAX → Chaptered MP3 Converter
# Handles books with multiple AAX files that need to be processed together
# Supports organizing chapters into sub-books (e.g., Chronicles of Narnia collection)

set -euo pipefail

# ==================== CONFIGURATION ====================
BASE_DIR="/home/mg/repos/AAXtoMP3/audible_books"
AAXTOMP3="./AAXtoMP3"
TEMP_DIR="/tmp/aax_processing"
# =======================================================

# Timestamped log file in script directory
LOG_DIR="$(dirname "$0")"
LOG_FILE="$LOG_DIR/convert_multipart_$(date +%Y-%m-%d_%H-%M-%S).log"

# Log everything to terminal + file
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "============================================================"
echo "Multi-Part AAX to Chaptered MP3 Converter - Started at $(date)"
echo "Log file: $LOG_FILE"
echo "============================================================"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

This script handles audiobooks split across multiple AAX files.
It can merge them and organize chapters into sub-books if JSON contains book names.

Options:
  --book "Title"      Process only books whose folder contains this text (required)
  --merge-only        Only merge AAX files, don't split into chapters yet
  --split-existing "file.mp3"  Split an existing merged MP3 file using JSON chapter data
  --split-by-book     Parse chapter titles and organize by book name (e.g., "The Magician's Nephew")
  --decode-first      Decode each AAX to MP3 first, then combine (slower but more reliable)
  --dry-run           Show what would run without converting
  --keep-merged       Keep the merged file after processing
  --use-cli-data      Use audible-cli JSON chapter data (required for --split-by-book)
  --help              Show this help

Examples:
  # Simple merge and chapter split (standard behavior):
  $0 --book "Narnia"

  # If you get AAC codec errors, use decode-first method (RECOMMENDED):
  $0 --book "Narnia" --decode-first --use-cli-data

  # Organize into sub-books based on chapter titles:
  $0 --book "Narnia" --split-by-book --use-cli-data --decode-first

  # Just merge the files for inspection:
  $0 --book "Narnia" --merge-only --keep-merged

  # Split an existing merged MP3 file:
  $0 --book "Narnia" --split-existing "/path/to/merged.mp3" --use-cli-data

  # Dry run to see what would happen:
  $0 --book "Dune" --dry-run

Directory Structure:
  Input:  BASE_DIR/Author/Book_Title/*.aax (multiple files)
          BASE_DIR/Author/Book_Title/*-chapters.json (required for --use-cli-data)
  Output: BASE_DIR/Author/Book_Title/chapters/*.mp3 (standard)
          BASE_DIR/Author/Book_Title/chapters/BookName/*.mp3 (with --split-by-book)
  
  For --split-existing:
  Input:  /path/to/merged.mp3 (your existing merged file)
          BASE_DIR/Author/Book_Title/*-chapters.json (required)
  Output: BASE_DIR/Author/Book_Title/chapters/*.mp3
EOF
    exit 1
}

# Defaults
BOOK_FILTER=""
DRY_RUN=false
MERGE_ONLY=false
SPLIT_BY_BOOK=false
KEEP_MERGED=false
USE_CLI_DATA=false
DECODE_FIRST=false
SPLIT_EXISTING=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --book)
            [[ -z "${2:-}" ]] && echo "Error: --book requires an argument" && usage
            BOOK_FILTER="$2"
            shift 2
            ;;
        --merge-only)   MERGE_ONLY=true ; shift ;;
        --split-existing)
            [[ -z "${2:-}" ]] && echo "Error: --split-existing requires a file path" && usage
            SPLIT_EXISTING="$2"
            shift 2
            ;;
        --split-by-book) SPLIT_BY_BOOK=true ; shift ;;
        --keep-merged)  KEEP_MERGED=true ; shift ;;
        --use-cli-data) USE_CLI_DATA=true ; shift ;;
        --decode-first) DECODE_FIRST=true ; shift ;;
        --dry-run)      DRY_RUN=true ; shift ;;
        --help)         usage ;;
        *) echo "Unknown option: $1" ; usage ;;
    esac
done

if [[ -z "$BOOK_FILTER" ]] && [[ -z "$SPLIT_EXISTING" ]]; then
    echo "ERROR: --book is required (or use --split-existing with a file path)"
    usage
fi

if [[ "$SPLIT_BY_BOOK" == true ]] && [[ "$USE_CLI_DATA" == false ]]; then
    echo "ERROR: --split-by-book requires --use-cli-data"
    exit 1
fi

if [[ -n "$SPLIT_EXISTING" ]]; then
    if [[ ! -f "$SPLIT_EXISTING" ]]; then
        echo "ERROR: File not found: $SPLIT_EXISTING"
        exit 1
    fi
    if [[ "$USE_CLI_DATA" == false ]]; then
        echo "ERROR: --split-existing requires --use-cli-data"
        exit 1
    fi
fi

if [[ ! -f "$AAXTOMP3" ]] && [[ -z "$SPLIT_EXISTING" ]]; then
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

if [[ -n "$SPLIT_EXISTING" ]]; then
    echo "Mode            : Split existing MP3 file"
    echo "MP3 file        : $SPLIT_EXISTING"
    echo "Book filter     : $( [[ -n "$BOOK_FILTER" ]] && echo "\"$BOOK_FILTER\"" || echo "(using MP3 location)" )"
else
    echo "Book filter     : \"$BOOK_FILTER\""
    echo "Merge strategy  : $( [[ "$DECODE_FIRST" == true ]] && echo "Decode-first (reliable)" || echo "Direct merge (fast)" )"
    echo "Merge only      : $MERGE_ONLY"
fi
echo "Split by book   : $SPLIT_BY_BOOK"
echo "Use CLI data    : $USE_CLI_DATA"
[[ -z "$SPLIT_EXISTING" ]] && echo "Keep merged     : $KEEP_MERGED"
[[ "$DRY_RUN" == true ]] && echo "DRY RUN         : Enabled"
echo "Base dir        : $BASE_DIR"
[[ -z "$SPLIT_EXISTING" ]] && echo "Authcode        : $( [[ -n "$AUTHCODE" ]] && echo "found" || echo "missing" )"
echo "============================================================"

# Function to split a combined MP3 into chapters using JSON metadata
split_mp3_by_json() {
    local mp3_file="$1"
    local json_file="$2"
    local output_dir="$3"
    local book_name="$4"
    
    echo "[SPLIT] Splitting MP3 into chapters using JSON metadata..."
    
    if [[ ! -r "$json_file" ]]; then
        echo "ERROR: JSON file not found: $json_file"
        return 1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is required to parse JSON chapter data"
        return 1
    fi
    
    if ! command -v bc &> /dev/null; then
        echo "ERROR: bc is required for calculations (install with: brew install bc or apt-get install bc)"
        return 1
    fi
    
    # Get total chapter count
    local chapter_count=$(jq -r '.content_metadata.chapter_info.chapters | length' "$json_file")
    echo "Found $chapter_count chapters in JSON"
    
    mkdir -p "$output_dir"
    
    # Process each chapter
    local chapter_num=1
    while IFS= read -r chapter_data; do
        local chapter_title=$(echo "$chapter_data" | jq -r '.title')
        local start_ms=$(echo "$chapter_data" | jq -r '.start_offset_ms')
        local length_ms=$(echo "$chapter_data" | jq -r '.length_ms')
        
        # Convert milliseconds to seconds
        local start_sec=$(echo "scale=3; $start_ms / 1000" | bc)
        local duration_sec=$(echo "scale=3; $length_ms / 1000" | bc)
        
        # Create output filename
        local chapter_file="${output_dir}/${book_name}-$(printf %03d $chapter_num).mp3"
        
        echo "  [$chapter_num/$chapter_count] $chapter_title"
        
        if [[ "$DRY_RUN" == false ]]; then
            # Extract chapter using ffmpeg
            if ffmpeg -hide_banner -loglevel error \
                -ss "$start_sec" -t "$duration_sec" \
                -i "$mp3_file" \
                -c copy \
                -metadata track="$chapter_num" \
                -metadata title="$chapter_title" \
                "$chapter_file" 2>/dev/null; then
                :  # Success, continue
            else
                echo "             WARNING: Failed to extract chapter $chapter_num"
            fi
        fi
        
        ((chapter_num++))
    done < <(jq -c '.content_metadata.chapter_info.chapters[]' "$json_file")
    
    echo "[SPLIT] Complete! Created $chapter_count chapter files"
}

# Function to extract book name from chapter title
# Example: "The Magician's Nephew - Chapter 1" -> "The_Magicians_Nephew"
extract_book_name() {
    local chapter_title="$1"
    # Extract everything before the first " - Chapter" or " - Dedication" etc.
    local book_name=$(echo "$chapter_title" | sed -E 's/ - (Chapter|Dedication|Opening|End Credits).*//' | \
                      sed -E 's/[^a-zA-Z0-9]+/_/g' | sed -E 's/^_+|_+$//g')
    echo "$book_name"
}

# Function to merge multiple AAX files
merge_aax_files() {
    local book_dir="$1"
    local output_file="$2"
    
    echo "[MERGE] Finding AAX files in: $book_dir"
    
    # Find all AAX files and sort them
    local aax_files=()
    while IFS= read -r -d '' file; do
        aax_files+=("$file")
    done < <(find "$book_dir" -maxdepth 1 -type f \( -name "*.aax" -o -name "*.aaxc" \) -print0 | sort -z)
    
    local count=${#aax_files[@]}
    
    if [[ $count -eq 0 ]]; then
        echo "ERROR: No AAX files found in $book_dir"
        return 1
    fi
    
    echo "Found $count AAX file(s):"
    for f in "${aax_files[@]}"; do
        echo "  - $(basename "$f")"
    done
    
    if [[ $count -eq 1 ]]; then
        echo "Only one file, no merge needed. Using: ${aax_files[0]}"
        echo "${aax_files[0]}"
        return 0
    fi
    
    # Multiple files - need to merge
    echo "[MERGE] Concatenating $count files..."
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY RUN] Would merge to: $output_file"
        echo "${aax_files[0]}"  # Return first file for dry run
        return 0
    fi
    
    # Create concat list for ffmpeg
    local concat_list="${output_file}.list"
    > "$concat_list"  # Clear file
    
    for aax in "${aax_files[@]}"; do
        echo "file '$aax'" >> "$concat_list"
    done
    
    # Determine if we're working with aax or aaxc
    local ext="${aax_files[0]##*.}"
    local decrypt_opts=""
    
    if [[ "$ext" == "aaxc" ]]; then
        # For aaxc, we need the voucher file
        local voucher="${aax_files[0]%.*}.voucher"
        if [[ ! -r "$voucher" ]]; then
            echo "ERROR: AAXC voucher file not found: $voucher"
            return 1
        fi
        
        # Extract key and iv using jq
        if ! command -v jq &> /dev/null; then
            echo "ERROR: jq is required for AAXC files"
            return 1
        fi
        
        local key=$(jq -r '.content_license.license_response.key' "$voucher")
        local iv=$(jq -r '.content_license.license_response.iv' "$voucher")
        decrypt_opts="-audible_key $key -audible_iv $iv"
    else
        decrypt_opts="-activation_bytes $AUTHCODE"
    fi
    
    echo "Merging with ffmpeg (this may take a while)..."
    
    # Use ffmpeg to concatenate
    # We use copy codec to avoid re-encoding (fast)
    # Add error_detection flags to handle malformed AAC streams
    if ffmpeg -hide_banner -loglevel error -stats \
        -err_detect ignore_err \
        $decrypt_opts \
        -f concat -safe 0 -i "$concat_list" \
        -c copy \
        -bsf:a aac_adtstoasc \
        "$output_file"; then
        echo "SUCCESS: Merged file created: $output_file"
        rm "$concat_list"
        echo "$output_file"
        return 0
    else
        echo "ERROR: Failed to merge AAX files"
        rm -f "$concat_list"
        return 1
    fi
}

# Function to decode each AAX to MP3 first, then combine
# This is slower but avoids AAC codec issues
decode_and_merge_aax_files() {
    local book_dir="$1"
    local output_file="$2"
    
    echo "[DECODE-MERGE] Finding AAX files in: $book_dir"
    
    # Find all AAX files and sort them
    local aax_files=()
    while IFS= read -r -d '' file; do
        aax_files+=("$file")
    done < <(find "$book_dir" -maxdepth 1 -type f \( -name "*.aax" -o -name "*.aaxc" \) -print0 | sort -z)
    
    local count=${#aax_files[@]}
    
    if [[ $count -eq 0 ]]; then
        echo "ERROR: No AAX files found in $book_dir"
        return 1
    fi
    
    echo "Found $count AAX file(s):"
    for f in "${aax_files[@]}"; do
        echo "  - $(basename "$f")"
    done
    
    if [[ $count -eq 1 ]]; then
        echo "Only one file, no merge needed. Using: ${aax_files[0]}"
        echo "${aax_files[0]}"
        return 0
    fi
    
    # Multiple files - decode each to MP3, then combine
    echo "[DECODE-MERGE] This will decode $count files to MP3, then combine them."
    echo "               This is slower but avoids AAC codec errors."
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY RUN] Would decode and merge to: $output_file"
        echo "${aax_files[0]}"  # Return first file for dry run
        return 0
    fi
    
    # Create temp directory for decoded MP3s
    local temp_mp3_dir="${TEMP_DIR}/mp3_parts_$$"
    mkdir -p "$temp_mp3_dir"
    
    # Determine decrypt options
    local ext="${aax_files[0]##*.}"
    local decrypt_opts=""
    
    if [[ "$ext" == "aaxc" ]]; then
        # For aaxc, we need the voucher file
        local voucher="${aax_files[0]%.*}.voucher"
        if [[ ! -r "$voucher" ]]; then
            echo "ERROR: AAXC voucher file not found: $voucher"
            return 1
        fi
        
        if ! command -v jq &> /dev/null; then
            echo "ERROR: jq is required for AAXC files"
            return 1
        fi
        
        local key=$(jq -r '.content_license.license_response.key' "$voucher")
        local iv=$(jq -r '.content_license.license_response.iv' "$voucher")
        decrypt_opts="-audible_key $key -audible_iv $iv"
    else
        decrypt_opts="-activation_bytes $AUTHCODE"
    fi
    
    # Step 1: Decode each AAX to MP3
    echo ""
    echo "Step 1: Decoding each AAX file to MP3..."
    local decoded_files=()
    local part_num=1
    
    for aax in "${aax_files[@]}"; do
        local basename=$(basename "$aax" | sed 's/\.[^.]*$//')
        local mp3_output="${temp_mp3_dir}/part_$(printf %03d $part_num).mp3"
        
        echo "  [$part_num/$count] Decoding $(basename "$aax")..."
        
        # Decode AAX to MP3 with error tolerance
        if ffmpeg -hide_banner -loglevel error -stats \
            -err_detect ignore_err \
            $decrypt_opts \
            -i "$aax" \
            -vn \
            -codec:a libmp3lame \
            -q:a 2 \
            -ar 44100 \
            "$mp3_output"; then
            echo "             SUCCESS: $mp3_output"
            decoded_files+=("$mp3_output")
        else
            echo "             ERROR: Failed to decode $(basename "$aax")"
            # Cleanup and return error
            rm -rf "$temp_mp3_dir"
            return 1
        fi
        
        ((part_num++))
    done
    
    echo ""
    echo "Step 2: Combining MP3 files..."
    
    # Create concat list for MP3s
    local concat_list="${temp_mp3_dir}/concat.txt"
    > "$concat_list"
    
    for mp3 in "${decoded_files[@]}"; do
        echo "file '$mp3'" >> "$concat_list"
    done
    
    # Combine MP3s - no decryption needed, just concat
    if ffmpeg -hide_banner -loglevel error -stats \
        -f concat -safe 0 -i "$concat_list" \
        -c copy \
        "$output_file"; then
        echo "SUCCESS: Combined MP3 created: $output_file"
        rm -rf "$temp_mp3_dir"
        echo "$output_file"
        return 0
    else
        echo "ERROR: Failed to combine MP3 files"
        rm -rf "$temp_mp3_dir"
        return 1
    fi
}

# Function to organize chapters by book name
organize_by_books() {
    local chapters_dir="$1"
    local json_file="$2"
    
    if [[ ! -r "$json_file" ]]; then
        echo "ERROR: JSON file not found: $json_file"
        return 1
    fi
    
    echo "[ORGANIZE] Parsing chapter data from JSON..."
    
    # Extract chapter titles and determine unique books
    local -A books
    local chapter_num=1
    
    while IFS= read -r chapter_title; do
        local book_name=$(extract_book_name "$chapter_title")
        if [[ -n "$book_name" ]]; then
            books["$book_name"]=1
        fi
    done < <(jq -r '.content_metadata.chapter_info.chapters[].title' "$json_file" 2>/dev/null)
    
    if [[ ${#books[@]} -eq 0 ]]; then
        echo "WARNING: No distinct books found in chapter titles"
        return 1
    fi
    
    echo "Found ${#books[@]} distinct book(s):"
    for book in "${!books[@]}"; do
        echo "  - $book"
        mkdir -p "$chapters_dir/$book"
    done
    
    # Move chapter files into book subdirectories
    echo "[ORGANIZE] Moving chapters into book folders..."
    
    chapter_num=1
    while IFS= read -r chapter_title; do
        local book_name=$(extract_book_name "$chapter_title")
        if [[ -z "$book_name" ]]; then
            ((chapter_num++))
            continue
        fi
        
        # Find the chapter file (format: BookFolder-001.mp3)
        local chapter_pattern="${chapters_dir}/*-$(printf "%03d" $chapter_num).mp3"
        local chapter_files=( $chapter_pattern )
        
        if [[ -f "${chapter_files[0]}" ]]; then
            local old_file="${chapter_files[0]}"
            local new_file="$chapters_dir/$book_name/$(basename "$old_file")"
            
            if [[ "$DRY_RUN" == true ]]; then
                echo "[DRY RUN] Would move: $(basename "$old_file") -> $book_name/"
            else
                mv "$old_file" "$new_file"
                echo "  [$chapter_num] -> $book_name/"
            fi
        fi
        
        ((chapter_num++))
    done < <(jq -r '.content_metadata.chapter_info.chapters[].title' "$json_file" 2>/dev/null)
    
    echo "[ORGANIZE] Complete!"
}

# Main processing function
process_multipart_book() {
    local book_dir="$1"
    local book_name=$(basename "$book_dir")
    
    echo ""
    echo "========================================================================"
    echo "[PROCESSING] $book_name"
    echo "========================================================================"
    
    local chapters_dir="${book_dir}/chapters"
    
    # Check if already processed
    if [[ -d "$chapters_dir" ]] && [[ -n "$(ls -A "$chapters_dir" 2>/dev/null)" ]]; then
        echo "[SKIP] Already converted (chapters directory exists and is not empty)"
        return 0
    fi
    
    # Setup temp directory
    mkdir -p "$TEMP_DIR"
    
    # Step 1: Merge AAX files (choose strategy based on flag)
    local source_file
    if [[ "$DECODE_FIRST" == true ]]; then
        # Decode each AAX to MP3, then combine (slower but more reliable)
        local merged_file="$TEMP_DIR/${book_name}_merged.mp3"
        if ! source_file=$(decode_and_merge_aax_files "$book_dir" "$merged_file"); then
            echo "ERROR: Failed to decode and merge files"
            return 1
        fi
    else
        # Direct merge with copy codec (fast but can have AAC issues)
        local merged_file="$TEMP_DIR/${book_name}_merged.m4b"
        if ! source_file=$(merge_aax_files "$book_dir" "$merged_file"); then
            echo "ERROR: Failed to merge files"
            echo "TIP: Try again with --decode-first flag for better compatibility"
            return 1
        fi
    fi
    
    if [[ "$MERGE_ONLY" == true ]]; then
        echo "[MERGE-ONLY] Stopping after merge. File: $source_file"
        if [[ "$source_file" == "$merged_file" ]] && [[ "$KEEP_MERGED" == true ]]; then
            local keep_location="${book_dir}/$(basename "$merged_file")"
            mv "$merged_file" "$keep_location"
            echo "Merged file saved to: $keep_location"
        fi
        return 0
    fi
    
    # Step 2: Convert to chapters
    echo ""
    mkdir -p "$chapters_dir"
    
    if [[ "$DECODE_FIRST" == true ]]; then
        # We have a combined MP3, split it using JSON metadata
        echo "[CONVERT] Splitting combined MP3 into chapters..."
        
        if [[ "$USE_CLI_DATA" != true ]]; then
            echo "ERROR: --decode-first requires --use-cli-data for chapter information"
            return 1
        fi
        
        # Find JSON file
        local json_file="${book_dir}/${book_name}-chapters.json"
        if [[ ! -r "$json_file" ]]; then
            json_file=$(find "$book_dir" -maxdepth 1 -name "*-chapters.json" | head -1)
        fi
        
        if [[ ! -r "$json_file" ]]; then
            echo "ERROR: No JSON chapter file found in $book_dir"
            echo "       Need *-chapters.json file from audible-cli"
            return 1
        fi
        
        if ! split_mp3_by_json "$source_file" "$json_file" "$chapters_dir" "$book_name"; then
            echo "[FAILED] Chapter splitting failed"
            return 1
        fi
        
        echo "[SUCCESS] Chapter splitting complete"
        
    else
        # Use AAXtoMP3 for direct AAX processing
        echo "[CONVERT] Converting to chaptered MP3s with AAXtoMP3..."
        
        local cli_data_flag=""
        if [[ "$USE_CLI_DATA" == true ]]; then
            cli_data_flag="--use-audible-cli-data"
        fi
        
        local cmd="$AAXTOMP3 --chaptered --level 5 --target_dir \"$chapters_dir\" --dir-naming-scheme ''"
        [[ -n "$AUTHCODE" ]] && cmd="$cmd --authcode $AUTHCODE"
        [[ -n "$cli_data_flag" ]] && cmd="$cmd $cli_data_flag"
        cmd="$cmd \"$source_file\""
        
        echo "Running: $cmd"
        
        if [[ "$DRY_RUN" == false ]]; then
            if eval "$cmd"; then
                echo "[SUCCESS] Conversion complete"
            else
                echo "[FAILED] Conversion failed (code $?)"
                return 1
            fi
        else
            echo "[DRY RUN] Would convert with AAXtoMP3"
        fi
    fi
    
    # Step 3: Organize by books if requested
    if [[ "$SPLIT_BY_BOOK" == true ]]; then
        echo ""
        local json_file="${book_dir}/${book_name}-chapters.json"
        if [[ ! -r "$json_file" ]]; then
            # Try alternate naming
            json_file=$(find "$book_dir" -maxdepth 1 -name "*-chapters.json" | head -1)
        fi
        
        if [[ -r "$json_file" ]]; then
            organize_by_books "$chapters_dir" "$json_file"
        else
            echo "WARNING: No JSON chapter file found, cannot organize by books"
            echo "         Searched for: ${book_dir}/*-chapters.json"
        fi
    fi
    
    # Cleanup
    if [[ "$KEEP_MERGED" == false ]] && [[ -f "$merged_file" ]]; then
        echo "[CLEANUP] Removing temporary merged file"
        rm -f "$merged_file"
    elif [[ "$KEEP_MERGED" == true ]] && [[ -f "$merged_file" ]]; then
        local keep_location="${book_dir}/$(basename "$merged_file")"
        mv "$merged_file" "$keep_location"
        echo "Merged file kept at: $keep_location"
    fi
    
    echo ""
    echo "[COMPLETE] $book_name"
    echo "Output: $chapters_dir"
}

# Special mode: Split an existing MP3 file
if [[ -n "$SPLIT_EXISTING" ]]; then
    echo ""
    echo "========================================================================"
    echo "[SPLIT EXISTING] Processing existing MP3 file"
    echo "========================================================================"
    echo "MP3 file: $SPLIT_EXISTING"
    
    # Determine book directory from the MP3 file location or book filter
    mp3_dir=$(dirname "$SPLIT_EXISTING")
    mp3_name=$(basename "$SPLIT_EXISTING" .mp3)
    
    # If book filter is provided, use it to find the book directory
    if [[ -n "$BOOK_FILTER" ]]; then
        book_dir=$(find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0 | \
                   while IFS= read -r -d '' dir; do
                       if echo "$(basename "$dir")" | grep -iq "$BOOK_FILTER"; then
                           echo "$dir"
                           break
                       fi
                   done)
        
        if [[ -z "$book_dir" ]]; then
            echo "ERROR: Could not find book directory matching: $BOOK_FILTER"
            exit 1
        fi
    else
        # Use the MP3 file's directory as the book directory
        book_dir="$mp3_dir"
    fi
    
    book_name=$(basename "$book_dir")
    chapters_dir="${book_dir}/chapters"
    
    echo "Book directory: $book_dir"
    echo "Output directory: $chapters_dir"
    echo ""
    
    # Find JSON file
    json_file="${book_dir}/${book_name}-chapters.json"
    if [[ ! -r "$json_file" ]]; then
        json_file=$(find "$book_dir" -maxdepth 1 -name "*-chapters.json" | head -1)
    fi
    
    if [[ ! -r "$json_file" ]]; then
        echo "ERROR: No JSON chapter file found in $book_dir"
        echo "       Need *-chapters.json file from audible-cli"
        exit 1
    fi
    
    echo "Using JSON: $json_file"
    echo ""
    
    # Create output directory
    mkdir -p "$chapters_dir"
    
    # Split the MP3
    if ! split_mp3_by_json "$SPLIT_EXISTING" "$json_file" "$chapters_dir" "$book_name"; then
        echo "[FAILED] Chapter splitting failed"
        exit 1
    fi
    
    echo "[SUCCESS] Chapter splitting complete"
    
    # Organize by books if requested
    if [[ "$SPLIT_BY_BOOK" == true ]]; then
        echo ""
        organize_by_books "$chapters_dir" "$json_file"
    fi
    
    echo ""
    echo "============================================================"
    echo "[COMPLETE] Split existing MP3 successfully"
    echo "Output: $chapters_dir"
    echo "Finished at $(date)"
    echo "============================================================"
    exit 0
fi

# Main execution
matched_dirs=()

while IFS= read -r -d '' book_dir; do
    book_name=$(basename "$book_dir")
    
    if ! echo "$book_name" | grep -iq "$BOOK_FILTER"; then
        continue
    fi
    
    matched_dirs+=("$book_dir")
done < <(find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0)

if [[ ${#matched_dirs[@]} -eq 0 ]]; then
    echo "ERROR: No book directories matched filter: \"$BOOK_FILTER\""
    echo "Searched in: $BASE_DIR"
    exit 1
fi

echo ""
echo "Found ${#matched_dirs[@]} matching book(s):"
for dir in "${matched_dirs[@]}"; do
    echo "  - $(basename "$dir")"
done
echo ""

if [[ "$DRY_RUN" == true ]]; then
    read -p "Proceed with DRY RUN? (y/N) " -n 1 -r REPLY
else
    read -p "Proceed with conversion? (y/N) " -n 1 -r REPLY
fi
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Process each matched book
for book_dir in "${matched_dirs[@]}"; do
    process_multipart_book "$book_dir"
done

# Final cleanup
if [[ -d "$TEMP_DIR" ]] && [[ -z "$(ls -A "$TEMP_DIR" 2>/dev/null)" ]]; then
    rmdir "$TEMP_DIR"
fi

echo ""
echo "============================================================"
echo "All processing complete!"
echo "Finished at $(date)"
echo "Log saved: $LOG_FILE"
echo "============================================================"
