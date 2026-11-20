# convertsub
A script that will keep only wanted subtitles from MKV files. Call the script with a trailing directory path and it will process the items in that location. By default it keeps eng, and und (undefined).

*Process*
When processing files, the changes are written to a temp file. Upon success, the original file is removed and replaced with the updated version.

# convertsubsingle
A script that will keep only wanted subtitles from a single MKV file. Call the script with a trailing file path and it will process the items in that location. By default it keeps eng, and und (undefined).

This one is useful to call with a tool like Tdarr for use in a flow. Your Tdarr OS will still require the below dependencies.  If Tdarr ever includes the below items available to flows, I'd probably do a proper plug-in for it.

*Requirements*

1. mkvmerge
2. mkvpropedit
3. jq
