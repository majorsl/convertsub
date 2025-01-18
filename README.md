# convertsub
A script that will keep only wanted subtitles from MKV files. Call the script with a trailing directory path and it will process the items in that location.

*Process*
When processing files, the changes are written to a temp file. Upon success, the original file is removed and replaced with the updated version.

*Requirements*

1. ffmpeg
2. jq
