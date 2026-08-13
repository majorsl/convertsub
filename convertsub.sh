#!/usr/bin/env bash
# Version 1.1.0

MKVMERGE="/usr/bin/"
JQ="/usr/bin/"

IFS=$'\n'

# Check for required tools
if ! command -v "${JQ}jq" &> /dev/null; then
    echo "❌ jq could not be found. Please install it."
    exit 1
fi

if ! command -v "${MKVMERGE}mkvmerge" &> /dev/null; then
    echo "❌ mkvmerge could not be found. Please install it."
    exit 1
fi

LOCKFILE="/tmp/convertsub.lock"
ABORTFILE="/tmp/convertsub.abort"

exec 9>"$LOCKFILE"
echo "Waiting for convertsub lock..."
flock -w 1800 9 || {
    echo "❌ Failed to acquire convertsub lock within 30 minutes. Exiting."
    exit 1
}
echo "Acquired convertsub lock."

# --- Abort handling ---
cleanup() {
    rm -f "$LOCKFILE" "$ABORTFILE"

    # Kill watcher if still alive
    if [[ -n "$WATCHER_PID" ]] && kill -0 "$WATCHER_PID" 2>/dev/null; then
        kill "$WATCHER_PID" 2>/dev/null
    fi

    echo "🧹 Lockfile, abort flag, and watcher cleaned up."
}
trap 'echo "⚠️ Abort requested. Waiting for current remux to finish..."; echo "1" > "$ABORTFILE"' SIGINT SIGTERM
trap cleanup EXIT

# Background monitor for 'q' key
(
  while true; do
    # If read fails (TTY closed), exit watcher cleanly
    if ! read -r -n1 key < /dev/tty; then
      break
    fi

    if [[ $key == "q" ]]; then
      echo "⚠️ 'q' pressed. Will stop after current file."
      echo "1" > "$ABORTFILE"
      break
    fi
  done
) &
WATCHER_PID=$!

# SDH detection
is_sdh() {
    local title="$1"
    local hearing="$2"

    [[ "$hearing" == "1" ]] && return 0

    if [[ "$title" =~ [Ss][Dd][Hh] ||
          "$title" =~ [Cc][Cc] ||
          "$title" =~ [Hh]earing ||
          "$title" =~ [Cc]losed[[:space:]]*[Cc]aptions ||
          "$title" =~ [Hh][Ii] ]]; then
        return 0
    fi

    return 1
}

# Language normalization
normalize_lang() {
    case "$1" in
        en|eng) echo "English" ;;
        ja|jpn) echo "Japanese" ;;
        zh|zho|chi) echo "Chinese" ;;
        ko|kor) echo "Korean" ;;
        fr|fra|fre) echo "French" ;;
        es|spa) echo "Spanish" ;;
        de|ger|deu) echo "German" ;;
        it|ita) echo "Italian" ;;
        ru|rus) echo "Russian" ;;
        pt|por) echo "Portuguese" ;;
        *) echo "$1" ;;
    esac
}

# SDH-only mode
SDH_ONLY=0
if [[ "$1" == "--sdh" ]]; then
    SDH_ONLY=1
    shift
fi

process_file() {
    local input_file="$1"
    
    echo "🎬 Processing: $input_file"

    local json=$("${MKVMERGE}mkvmerge" -J "$input_file")
    local tracks_json=$(echo "$json" | "${JQ}jq" -c '.tracks[] | select(.type=="subtitles")')

    local tracks_to_keep=()
    local track_name_args=()

    while read -r track; do
        [[ -z "$track" ]] && continue

        local id=$(echo "$track" | "${JQ}jq" -r '.id')
        local lang=$(echo "$track" | "${JQ}jq" -r '.properties.language // "und"')
        local title=$(echo "$track" | "${JQ}jq" -r '.properties.track_name // ""')
        local hearing=$(echo "$track" | "${JQ}jq" -r '.properties.hearing_impaired // 0')
        local forced=$(echo "$track" | "${JQ}jq" -r '.properties.forced // 0')

        if is_sdh "$title" "$hearing"; then
            echo "💬 SDH detected on track ID $id → removing"
            continue
        fi

        if [[ "$SDH_ONLY" -eq 1 ]]; then
            tracks_to_keep+=("$id")
        else
            if [[ "$lang" != "en" && "$lang" != "eng" && "$lang" != "und" ]]; then
                echo "🧹 Removing non-English subtitle track ID $id ($lang)"
                continue
            fi
            tracks_to_keep+=("$id")
        fi

        local nice_lang=$(normalize_lang "$lang")
        title=$(echo "$title" | sed 's/[Ss]ubtitle//g; s/[Pp][Gg][Ss]//g; s/[Ss]ub//g; s/default//g' | xargs)
        local new_title="$nice_lang"
        [[ "$forced" == "1" ]] && new_title="$new_title (Forced)"
        track_name_args+=("--track-name" "$id:$new_title")

    done <<< "$tracks_json"

    echo "📌 Tracks to keep (IDs): ${tracks_to_keep[*]}"

    local original_ids=($(echo "$tracks_json" | "${JQ}jq" -r '.id'))
    if [[ "${original_ids[*]}" == "${tracks_to_keep[*]}" ]]; then
        echo "ℹ️ No subtitle changes needed — skipping mux."
        return
    fi

    if [[ ${#tracks_to_keep[@]} -eq 0 ]]; then
        echo "🧹 No subtitle tracks remain after filtering - muxing file with no subtitles."
    fi

    local output_file="${input_file%.mkv}-no-subtitles.mkv"
    
    local keep_args=()
    if [[ ${#tracks_to_keep[@]} -gt 0 ]]; then
        keep_args=(--subtitle-tracks "$(IFS=,; echo "${tracks_to_keep[*]}")")
    else
        keep_args=(--no-subtitles)
    fi

    "${MKVMERGE}mkvmerge" -o "$output_file" \
        "${keep_args[@]}" \
        "${track_name_args[@]}" \
        "$input_file" || {
        echo "⚠️ Error processing file: $input_file"
        return 1
    }

    if [[ -f "$output_file" ]]; then
        mv "$output_file" "$input_file"
        echo "✅ Successfully updated file: $input_file"
    else
        echo "⚠️ Error: New file was not created."
        return 1
    fi
}

if [ -n "$1" ]; then
  dir="$1"
else
  echo "⚠️ Please call the script with a trailing directory part to process."
  exit 0
fi

if [ ! -d "$dir" ]; then
  echo "❌ Directory doesn't exist, aborting."
  exit
fi

# Lazy iteration over files
while IFS= read -r file; do
    if [[ -f "$ABORTFILE" ]]; then
        echo "🛑 Aborting before processing $file"
        break
    fi

    process_file "$file"

    if [[ -f "$ABORTFILE" ]]; then
        echo "🛑 Aborting after finishing $file"
        break
    fi
done < <(find "$dir" -type f -name "*.mkv")

unset IFS
