#!/usr/bin/env bash
# Version 1.2.2

MKVMERGE="/usr/bin/"
MKVPROPEDIT="/usr/bin/mkvpropedit"
JQ="/usr/bin/"

IFS=$'\n'

if ! command -v "${JQ}jq" &> /dev/null; then
    echo "❌ jq could not be found. Please install it."
    exit 1
fi

if ! command -v "${MKVMERGE}mkvmerge" &> /dev/null; then
    echo "❌ mkvmerge could not be found. Please install it."
    exit 1
fi

if [[ ! -x "$MKVPROPEDIT" ]]; then
    echo "❌ mkvpropedit could not be found at $MKVPROPEDIT"
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

cleanup() {
    rm -f "$LOCKFILE" "$ABORTFILE"
    if [[ -n "$WATCHER_PID" ]] && kill -0 "$WATCHER_PID" 2>/dev/null; then
        kill "$WATCHER_PID" 2>/dev/null
    fi
    echo "🧹 Lockfile, abort flag, and watcher cleaned up."
}

trap 'echo "⚠️ Abort requested. Waiting for current remux to finish..."; echo "1" > "$ABORTFILE"' SIGINT SIGTERM
trap cleanup EXIT

(
    while true; do
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

SDH_ONLY=0
if [[ "$1" == "--sdh" ]]; then
    SDH_ONLY=1
    shift
fi

process_file() {
    local input_file="$1"

    echo "🎬 Processing: $input_file"

    local json
    json=$("${MKVMERGE}mkvmerge" -J "$input_file") || {
        echo "⚠️ Error reading file: $input_file"
        return 1
    }

    local tracks_json
    tracks_json=$(echo "$json" | "${JQ}jq" -c '.tracks[] | select(.type=="subtitles")')

    local tracks_to_keep=()
    local original_ids=()

    local subtitle_ordinal=0

    local track_name_args=()
    local propedit_args=()

    local tracks_removed=0
    local metadata_changed=0

    while read -r track; do
        [[ -z "$track" ]] && continue

        local id
        local lang
        local lang_base
        local title
        local hearing
        local forced

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

        local propedit_track=$((subtitle_ordinal + 1))
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

        local nice_lang
        nice_lang=$(normalize_lang "$lang")

        title=$(echo "$title" |
            sed 's/[Ss]ubtitle//g; s/[Pp][Gg][Ss]//g; s/[Ss]ub//g; s/default//g' |
            xargs)

        local old_title="$title"
        local new_title

        if [[ "$old_title" =~ [Cc]ommentary|[Dd]irector|[Cc]ast|[Pp]roducer|[Ww]riter ]]; then
            local commentary_label="Commentary"

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
        echo "ℹ️ No subtitle tracks found — skipping."
        return 0
    fi

    if (( tracks_removed == 1 )); then
        if [[ ${#tracks_to_keep[@]} -eq 0 ]]; then
            echo "🧹 No subtitle tracks remain after filtering - muxing file with no subtitles."
        fi

        local output_file="${input_file%.mkv}-no-subtitles.mkv"

        local keep_args=()

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
            "$input_file" || {
            echo "⚠️ Error processing file: $input_file"
            rm -f "$output_file"
            return 1
        }

        if [[ -f "$output_file" ]]; then
            mv -f "$output_file" "$input_file"
            echo "✅ Successfully updated file: $input_file"
        else
            echo "⚠️ Error: New file was not created."
            return 1
        fi

    elif (( metadata_changed == 1 )); then
        echo "🏷️ Updating subtitle metadata in place..."

        "${MKVPROPEDIT}" \
            "$input_file" \
            "${propedit_args[@]}"

        local result=$?

        if [[ "$result" -eq 0 ]]; then
            echo "✅ Subtitle metadata updated in place: $input_file"
        elif [[ "$result" -eq 1 ]]; then
            echo "⚠️ Subtitle metadata updated with warnings: $input_file"
        else
            echo "❌ Error updating subtitle metadata: $input_file"
            return 1
        fi

    else
        echo "ℹ️ No subtitle changes needed — skipping mux."
    fi

    return 0
}

if [ -n "$1" ]; then
    dir="$1"
else
    echo "⚠️ Please call the script with a trailing directory part to process."
    exit 0
fi

if [ ! -d "$dir" ]; then
    echo "❌ Directory doesn't exist, aborting."
    exit 1
fi

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
