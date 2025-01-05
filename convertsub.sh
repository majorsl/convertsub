#!/usr/bin/env bash
# Version 1.0 *See README.md for requirements*
#
# SET YOUR OPTIONS HERE -------------------------------------------------------------------------
# Default directory to parse files recursively if not specified.
DEFAULT_WORKINGDIRECTORY="/media/majorsl/e9ef2c72-9134-4418-86dc-10742b12d0ed/Downloads/Sonarr/"
# Path to mkvmerge
MKVMERGE="/usr/bin/"
# Path to jq
JQ="/usr/bin/"
# Modify lines 34 and 44 for the subtitles you want to keep!
# -----------------------------------------------------------------------------------------------
IFS=$'\n'

# Check for required tools
if ! command -v "$JQ"jq &> /dev/null; then
    echo "jq could not be found. Please install it."
    exit 1
fi

if ! command -v "$MKVMERGE"mkvmerge &> /dev/null; then
    echo "mkvmerge could not be found. Please install it."
    exit 1
fi

# Function to process a single MKV file
process_file() {
    local input_file="$1"
    
    # Get the JSON metadata from mkvmerge
    local json=$("$MKVMERGE"mkvmerge -J "$input_file")

    # Parse the JSON to identify subtitle tracks to remove
    local tracks_to_remove=($(echo "$json" | "$JQ"jq -r '.tracks[] | select(.type == "subtitles" and .properties.language != "en" and .properties.language != "eng" and .properties.language != "und") | .properties.number'))
    
    # Display tracks to remove
    echo "Tracks to remove: ${tracks_to_remove[@]}"
    
    # If there are subtitle tracks to remove, run mkvmerge to create a new file
    if [ ${#tracks_to_remove[@]} -gt 0 ]; then
        local output_file="${input_file%.mkv}-no-subtitles.mkv"
        
        # Run mkvmerge to create the new file
        "$MKVMERGE"mkvmerge -o "$output_file" -s "en,eng,und" "$input_file" || {
            echo "Error processing file: $input_file"
            return 1
        }
        
        # If mkvmerge succeeds, overwrite the original file
        if [ -f "$output_file" ]; then
            mv "$output_file" "$input_file"
            echo "Successfully updated file: $input_file"
        else
            echo "Error: New file was not created."
            return 1
        fi
    else
        echo "No subtitle tracks to remove in: $input_file"
    fi
}

# Check if a directory is passed as an argument
if [ -n "$1" ]; then
  dir="$1"
else
  dir="$DEFAULT_WORKINGDIRECTORY"
fi

if [ ! -d "$dir" ]; then
  echo "Directory doesn't exist, aborting."
  exit
fi

# Find all MKV files in the directory and process each one
find "$dir" -type f -name "*.mkv" | while read -r file; do
    process_file "$file"
done
unset IFS