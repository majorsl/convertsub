#!/usr/bin/env bash
# Version 1.2.3-single
#
# Subtitle normalization/removal for a single MKV file.
#
# Usage: ./convertsub.sh [--sdh] /path/to/file.mkv
#
#   --sdh   Only remove SDH/CC/HI tracks; keep non-English subtitles.
#           (Default behavior removes SDH tracks AND non-English tracks.)
#
# Uses mkvmerge for stream analysis/remux and mkvpropedit for
# metadata-only changes.
#
# Single-file mode:
#   - No lockfile, no abort file, no tty watcher, no directory walk.
#   - Exit 0 on success.
#   - Exit 1 on mkvmerge/mkvpropedit failure.
#   - Exit 2 on usage / missing file error.
#   - Exit 3 on missing dependency.

MKVMERGE="/usr/bin/"
MKVPROPEDIT="/usr/bin/mkvpropedit"
JQ="/usr/bin/"

# --- Required programs ---
if ! command -v "${JQ}jq" &> /dev/null; then
    echo "❌ jq could not be found. Please install it."
    exit 3
fi

if ! command -v "${MKVMERGE}mkvmerge" &> /dev/null; then
    echo "❌ mkvmerge could not be found. Please install it."
    exit 3
fi

if [[ ! -x "$MKVPROPEDIT" ]]; then
    echo "❌ mkvpropedit could not be found at $MKVPROPEDIT"
    exit 3
fi

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

normalize_lang() {
    local lang="$1"

    # Use the base language from BCP 47-style tags such as en-US or khk-Cyrl.
    lang="${lang%%[-_]*}"

    case "$lang" in
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

# --- Argument handling ---
SDH_ONLY=0
if [[ "$1" == "--sdh" ]]; then
    SDH_ONLY=1
    shift
fi

if [[ -z "$1" ]]; then
    echo "Usage: $0 [--sdh] <file.mkv>"
    exit 2
fi

INPUT_FILE="$1"

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "❌ File not found: $INPUT_FILE"
    exit 2
fi

# --- Processing ---
echo "🎬 Processing: $INPUT_FILE"

json=$("${MKVMERGE}mkvmerge" -J "$INPUT_FILE") || {
    echo "⚠️ Error reading file: $INPUT_FILE"
    exit 1
}

tracks_json=$(echo "$json" | "${JQ}jq" -c '.tracks[] | select(.type=="subtitles")')

tracks_to_keep=()
original_ids=()

subtitle_ordinal=0

track_name_args=()
propedit_args=()

tracks_removed=0
metadata_changed=0

while IFS= read -r track; do
    [[ -z "$track" ]] && continue

    id=$(echo "$track" | "${JQ}jq" -r '.id')

    # Prefer the IETF language tag when present.
    # This prevents tracks such as:
    #   language=und, language_ietf=khk-Cyrl
    # from incorrectly being treated as undefined.
    lang=$(echo "$track" | "${JQ}jq" -r '
        .properties.language_ietf //
        .properties.language //
        "und"
    ')

    lang_base="${lang%%[-_]*}"

    title=$(echo "$track" | "${JQ}jq" -r '.properties.track_name // ""')
    hearing=$(echo "$track" | "${JQ}jq" -r '.properties.hearing_impaired // 0')
    forced=$(echo "$track" | "${JQ}jq" -r '.properties.forced // 0')

    original_ids+=("$id")

    propedit_track=$((subtitle_ordinal + 1))
    ((subtitle_ordinal++))

    if is_sdh "$title" "$hearing"; then
        echo "💬 SDH detected on track ID $id → removing"
        tracks_removed=1
        continue
    fi

    if [[ "$SDH_ONLY" -eq 1 ]]; then
        tracks_to_keep+=("$id")
    else
        if [[ "$lang_base" != "en" &&
              "$lang_base" != "eng" &&
              "$lang_base" != "und" ]]; then
            echo "🧹 Removing non-English subtitle track ID $id ($lang)"
            tracks_removed=1
            continue
        fi

        tracks_to_keep+=("$id")
    fi

    nice_lang=$(normalize_lang "$lang")

    title=$(echo "$title" |
        sed 's/[Ss]ubtitle//g; s/[Pp][Gg][Ss]//g; s/[Ss]ub//g; s/default//g' |
        xargs)

    old_title="$title"

    if [[ "$old_title" =~ [Cc]ommentary|[Dd]irector|[Cc]ast|[Pp]roducer|[Ww]riter ]]; then
        commentary_label="Commentary"

        [[ "$old_title" =~ [Dd]irector ]] && commentary_label="Director Commentary"
        [[ "$old_title" =~ [Cc]ast ]] && commentary_label="Cast Commentary"
        [[ "$old_title" =~ [Pp]roducer ]] && commentary_label="Producer Commentary"
        [[ "$old_title" =~ [Ww]riter ]] && commentary_label="Writer Commentary"

        new_title="$nice_lang $commentary_label"
    else
        new_title="$nice_lang"
    fi

    [[ "$forced" == "1" ]] && new_title="$new_title (Forced)"

    if [[ "$title" != "$new_title" ]]; then
        echo "🏷️  Subtitle track ID $id title -> \"$new_title\""

        track_name_args+=(
            "--track-name"
            "$id:$new_title"
        )

        propedit_args+=(
            --edit "track:s$propedit_track"
            --set "name=$new_title"
        )

        metadata_changed=1
    fi
done <<< "$tracks_json"

echo "📌 Tracks to keep (IDs): ${tracks_to_keep[*]}"

if [[ -z "$tracks_json" ]]; then
    echo "ℹ️ No subtitle tracks found — nothing to do."
    exit 0
fi

if (( tracks_removed == 1 )); then
    if [[ ${#tracks_to_keep[@]} -eq 0 ]]; then
        echo "🧹 No subtitle tracks remain after filtering - muxing file with no subtitles."
    fi

    output_file="${INPUT_FILE%.mkv}-no-subtitles.mkv"

    keep_args=()

    if [[ ${#tracks_to_keep[@]} -gt 0 ]]; then
        keep_args=(
            --subtitle-tracks
            "$(IFS=,; echo "${tracks_to_keep[*]}")"
        )
    else
        keep_args=(--no-subtitles)
    fi

    echo "🔄 Subtitle removal requires a remux..."

    "${MKVMERGE}mkvmerge" -o "$output_file" \
        "${keep_args[@]}" \
        "${track_name_args[@]}" \
        "$INPUT_FILE" || {
        echo "⚠️ Error processing file: $INPUT_FILE"
        rm -f "$output_file"
        exit 1
    }

    if [[ -f "$output_file" ]]; then
        mv -f "$output_file" "$INPUT_FILE"
        echo "✅ Successfully updated file: $INPUT_FILE"
        exit 0
    else
        echo "⚠️ Error: New file was not created."
        exit 1
    fi

elif (( metadata_changed == 1 )); then
    echo "🏷️ Updating subtitle metadata in place..."

    "${MKVPROPEDIT}" \
        "$INPUT_FILE" \
        "${propedit_args[@]}"

    result=$?

    if [[ "$result" -eq 0 ]]; then
        echo "✅ Subtitle metadata updated in place: $INPUT_FILE"
        exit 0
    elif [[ "$result" -eq 1 ]]; then
        echo "⚠️ Subtitle metadata updated with warnings: $INPUT_FILE"
        exit 0
    else
        echo "❌ Error updating subtitle metadata: $INPUT_FILE"
        exit 1
    fi

else
    echo "ℹ️ No subtitle changes needed — skipping mux."
    exit 0
fi

