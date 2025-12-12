# Multi-Part Audiobook Processing Guide

This guide explains how to process audiobooks that are split across multiple AAX files (5-6+ parts).

## Overview

The `convert_multipart_aax.sh` script handles three main scenarios:

1. **Simple multi-part books**: Books split across multiple AAX files that should become one collection of chapters
2. **Collection books**: Books with multiple "sub-books" (like Chronicles of Narnia = 7 books in one)
3. **Hybrid**: Multi-part AAX files that contain collections of sub-books

## Prerequisites

### Required
- `ffmpeg` with AAX support
- `jq` (for parsing JSON chapter data)
- Your Audible authcode in `.authcode` or `~/.authcode`
- Modified AAXtoMP3 script from `personal-tweaks` branch

### Optional (but recommended for collections)
- `audible-cli` with chapter JSON files downloaded
- Use `audible download --aaxc --chapter` to get detailed chapter info

## Directory Structure

Your audiobooks should be organized like this:

```
audible_books/
├── Lewis/
│   └── The_Chronicles_of_Narnia_Complete_Audio_Collection/
│       ├── Chronicles_Part1.aax
│       ├── Chronicles_Part2.aax
│       ├── Chronicles_Part3.aax
│       └── The_Chronicles_of_Narnia_Complete_Audio_Collection-chapters.json
└── Herbert/
    └── Dune_Complete_Series/
        ├── Dune_Part1.aax
        ├── Dune_Part2.aax
        ├── Dune_Part3.aax
        ├── Dune_Part4.aax
        ├── Dune_Part5.aax
        └── Dune_Complete_Series-chapters.json
```

## Usage Examples

### Scenario 1: Simple Multi-Part Book
**Goal**: Merge 5 AAX files and split into chapters

```bash
./convert_multipart_aax.sh --book "Dune"
```

**Result**:
```
audible_books/Herbert/Dune_Complete_Series/chapters/
├── Dune_Complete_Series-001.mp3
├── Dune_Complete_Series-002.mp3
├── Dune_Complete_Series-003.mp3
└── ... (all chapters in one folder)
```

### Scenario 2: Collection with Sub-Books (Chronicles of Narnia)
**Goal**: Merge parts AND organize chapters into individual books

```bash
./convert_multipart_aax.sh --book "Narnia" --split-by-book --use-cli-data
```

**Result**:
```
audible_books/Lewis/The_Chronicles_of_Narnia_Complete_Audio_Collection/chapters/
├── The_Magicians_Nephew/
│   ├── Chronicles-001.mp3
│   ├── Chronicles-002.mp3
│   └── ... (15 chapters)
├── The_Lion_the_Witch_and_the_Wardrobe/
│   ├── Chronicles-016.mp3
│   ├── Chronicles-017.mp3
│   └── ... (17 chapters)
├── The_Horse_and_His_Boy/
│   └── ... (15 chapters)
├── Prince_Caspian/
│   └── ... (15 chapters)
├── The_Voyage_of_the_Dawn_Treader/
│   └── ... (16 chapters)
├── The_Silver_Chair/
│   └── ... (16 chapters)
└── The_Last_Battle/
    └── ... (16 chapters)
```

### Scenario 3: Dry Run (Preview)
**Goal**: See what would happen without actually converting

```bash
./convert_multipart_aax.sh --book "Narnia" --split-by-book --use-cli-data --dry-run
```

### Scenario 4: Merge Only (for testing)
**Goal**: Just merge the AAX files to verify they work

```bash
./convert_multipart_aax.sh --book "Narnia" --merge-only --keep-merged
```

This creates a single merged `.m4b` file in the book directory for inspection.

## How It Works

### Step 1: File Discovery
The script finds all `.aax` or `.aaxc` files in the book directory and sorts them alphabetically.

### Step 2: Merging
If multiple AAX files are found, they are concatenated using `ffmpeg`:
- Uses `-c copy` for fast merging (no re-encoding)
- Preserves DRM decryption parameters
- Creates a temporary merged file

### Step 3: Chapter Splitting
The merged file (or single file) is passed to AAXtoMP3:
- Decodes and splits into individual chapter MP3s
- Uses your custom chapter naming from `personal-tweaks` branch
- Applies compression level 5 for good quality/size balance

### Step 4: Organization (Optional)
If `--split-by-book` is used:
- Parses the JSON chapter file
- Extracts book names from chapter titles (e.g., "The Magician's Nephew - Chapter 1")
- Creates subdirectories for each book
- Moves chapters into their respective book folders

## Command Reference

```
Usage: ./convert_multipart_aax.sh [OPTIONS]

Options:
  --book "Title"      Process only books whose folder contains this text (required)
  --merge-only        Only merge AAX files, don't split into chapters yet
  --split-by-book     Parse chapter titles and organize by book name
  --dry-run           Show what would run without converting
  --keep-merged       Keep the merged AAX file after processing
  --use-cli-data      Use audible-cli JSON chapter data (required for --split-by-book)
  --help              Show this help
```

## Troubleshooting

### "No AAX files found"
- Check that your AAX files are directly in the book folder (not in a subfolder)
- Verify file extensions are `.aax` or `.aaxc`

### "ERROR: AAXC voucher file not found"
- For `.aaxc` files, you need the `.voucher` file in the same directory
- Download it with `audible-cli`

### "No distinct books found in chapter titles"
- Your JSON file doesn't have book names in chapter titles
- Don't use `--split-by-book` for regular books
- Check the JSON structure matches the expected format

### "jq is required"
- Install jq: `sudo apt install jq` (Ubuntu/Debian) or `brew install jq` (macOS)

### Chapters are in wrong order
- AAX files must be named so they sort correctly (Part1, Part2, etc.)
- Use `ls -1` in the directory to verify sort order

## Performance Notes

- **Merging**: Fast (uses copy codec, no re-encoding)
- **Decoding**: Slow (depends on total audiobook length)
- **Chapter splitting**: Medium (depends on number of chapters)

For a 33-hour audiobook like Narnia:
- Merge: ~1-2 minutes
- Full decode + split: ~30-45 minutes (varies by CPU)

## Advanced: Manual Workflow

If you prefer more control, you can do this manually:

```bash
# 1. Navigate to your book directory
cd /home/mg/repos/AAXtoMP3/audible_books/Lewis/The_Chronicles_of_Narnia_Complete_Audio_Collection

# 2. Create a file list
for f in *.aax; do echo "file '$PWD/$f'"; done > concat.txt

# 3. Merge with ffmpeg
ffmpeg -activation_bytes YOUR_AUTHCODE \
       -f concat -safe 0 -i concat.txt \
       -c copy merged.m4b

# 4. Convert with AAXtoMP3
cd /home/mg/repos/AAXtoMP3
./AAXtoMP3 --chaptered --use-audible-cli-data --level 5 \
           --target_dir "/path/to/book/chapters" \
           --dir-naming-scheme '' \
           --authcode YOUR_AUTHCODE \
           "/path/to/merged.m4b"

# 5. If organizing by books, run a custom script or do it manually
```

## Best Practices

1. **Always do a dry run first**: `--dry-run` to verify detection
2. **Test with --merge-only**: Verify merging works before full conversion
3. **Keep JSON files**: Download chapter JSON with `audible-cli` for better metadata
4. **Backup your AAX files**: Keep originals in case something goes wrong
5. **Check disk space**: Temporary merged files can be large (1-2GB+)
6. **Use --keep-merged**: Helpful for debugging or creating archival M4B files

## Comparison with Original convert_aax.sh

| Feature | Original | Multi-Part |
|---------|----------|------------|
| Single AAX per book | ✅ | ✅ |
| Multiple AAX files | ❌ | ✅ |
| Auto-merge | ❌ | ✅ |
| Sub-book organization | ❌ | ✅ |
| JSON parsing | ❌ | ✅ |
| Batch processing | ✅ | ❌* |

*Multi-part script processes one book at a time (by design, for safety)

## Questions?

The script is verbose and shows exactly what it's doing. Check the log file for detailed information about any errors.
