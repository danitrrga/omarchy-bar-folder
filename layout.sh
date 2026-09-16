#!/bin/bash
# Moves widgets between the bar layout and Bar Folder, atomically.
#
#   layout.sh setup   <id>...                          first run: move these widgets into the folder
#   layout.sh absorb  <id> [index]                     bar -> folder (index -1 = end)
#   layout.sh release <id> [anchor-id] [before|after]  folder -> bar, next to anchor
#                                                      (default: just before the folder icon)
#   layout.sh reorder <id> <index>                     reorder inside the folder
#   layout.sh release-all                              put every widget back on the bar (before uninstalling)
#
# Inline bar settings travel along: absorbed entries keep them in
# widgetSettings[id], released entries get them back. Built-in tiles
# (builtin.*) have no bar widget, so releasing one just removes it.
# Nothing here runs unless the user drags something or confirms first-run setup.

set -euo pipefail

source omarchy-shell-config

FOLDER_ID="io.github.arikisonfire.bar-folder"
command=${1:?command required}
shift

valid_id() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $1 != *..* && $1 != "$FOLDER_ID" ]]
}

HELPERS='
  def entry_id: if type == "object" then (.id // "") else tostring end;
  def sections: ["left", "center", "right"];
  def insert_at($item; $index):
    if $index < 0 or $index > length then . + [$item] else .[:$index] + [$item] + .[$index:] end;
  def folder_update(f):
    .bar.layout |= with_entries(.value |= map(if entry_id == $folder then f else . end));
  def without_bar_entry($id):
    .bar.layout |= with_entries(.value |= map(select(entry_id != $id)));
  def require_folder:
    if ([.bar.layout[sections[]][] | select(entry_id == $folder)] | length) == 0
    then error("Bar Folder is not on the bar") else . end;
  def inline_settings($id):
    (first(.bar.layout[sections[]][] | select(entry_id == $id)) // null)
    | if type == "object" then del(.id) else {} end;
'

case $command in
  setup)
    for id in "$@"; do valid_id "$id" || fail "invalid id: $id"; done
    ids=$(printf '%s\n' "$@" | jq -R . | jq -s -c 'map(select(. != ""))')
    commit "$NORMALIZE | $HELPERS
      require_folder
      | folder_update(.widgets = (.widgets // []))
      | reduce \$ids[] as \$id (.;
          inline_settings(\$id) as \$inline
          | without_bar_entry(\$id)
          | folder_update(
              .widgets = (.widgets | map(select(. != \$id)) | . + [\$id])
              | if (\$inline | length) > 0
                then .widgetSettings = ((.widgetSettings // {}) + {(\$id): \$inline})
                else . end))
    " --arg folder "$FOLDER_ID" --argjson ids "$ids"
    ;;

  absorb)
    id=${1:?widget id required}
    index=${2:--1}
    valid_id "$id" || fail "invalid id: $id"
    [[ $index =~ ^-?[0-9]+$ ]] || fail "invalid index: $index"
    commit "$NORMALIZE | $HELPERS
      require_folder
      | inline_settings(\$id) as \$inline
      | without_bar_entry(\$id)
      | folder_update(
          .widgets = ((.widgets // []) | map(select(. != \$id)) | insert_at(\$id; \$index))
          | if (\$inline | length) > 0
            then .widgetSettings = ((.widgetSettings // {}) + {(\$id): \$inline})
            else . end)
    " --arg folder "$FOLDER_ID" --arg id "$id" --argjson index "$index"
    ;;

  release)
    id=${1:?widget id required}
    anchor=${2:-$FOLDER_ID}
    side=${3:-before}
    valid_id "$id" || fail "invalid id: $id"
    [[ $side == before || $side == after ]] || fail "invalid side: $side"
    [[ $anchor != "$id" ]] || anchor=$FOLDER_ID
    commit "$NORMALIZE | $HELPERS
      (first(.bar.layout[sections[]][] | select(entry_id == \$folder)) // {}) as \$host
      | ({id: \$id} + ((\$host.widgetSettings // {})[\$id] // {})) as \$entry
      | folder_update(
          .widgets = ((.widgets // []) | map(select(. != \$id)))
          | if .widgetSettings then .widgetSettings |= del(.[\$id]) else . end)
      | if (\$id | startswith(\"builtin.\")) then . else
          without_bar_entry(\$id)
          | (first(sections[] as \$s | select(any(.bar.layout[\$s][]; entry_id == \$anchor)) | \$s)
             // first(sections[] as \$s | select(any(.bar.layout[\$s][]; entry_id == \$folder)) | \$s)
             // \"right\") as \$section
          | .bar.layout[\$section] |= (
              (map(entry_id) | index(\$anchor)) as \$i
              | if \$i == null then . + [\$entry]
                elif \$after then insert_at(\$entry; \$i + 1)
                else insert_at(\$entry; \$i) end)
        end
    " --arg folder "$FOLDER_ID" --arg id "$id" --arg anchor "$anchor" \
      --argjson after "$([[ $side == after ]] && echo true || echo false)"
    ;;

  release-all)
    # Before uninstalling: every widget goes back to the bar, just before the folder.
    commit "$NORMALIZE | $HELPERS
      (first(.bar.layout[sections[]][] | select(entry_id == \$folder)) // null) as \$host
      | if \$host == null then . else
          ((\$host.widgets // []) | map(select(startswith(\"builtin.\") | not))) as \$ids
          | reduce \$ids[] as \$id (.;
              ({id: \$id} + ((\$host.widgetSettings // {})[\$id] // {})) as \$entry
              | without_bar_entry(\$id)
              | (first(sections[] as \$s | select(any(.bar.layout[\$s][]; entry_id == \$folder)) | \$s)) as \$section
              | .bar.layout[\$section] |= (
                  (map(entry_id) | index(\$folder)) as \$i | insert_at(\$entry; \$i)))
          | folder_update(.widgets = [] | del(.widgetSettings))
        end
    " --arg folder "$FOLDER_ID"
    ;;

  reorder)
    id=${1:?widget id required}
    index=${2:?index required}
    valid_id "$id" || fail "invalid id: $id"
    [[ $index =~ ^[0-9]+$ ]] || fail "invalid index: $index"
    commit "$NORMALIZE | $HELPERS
      folder_update(.widgets = ((.widgets // []) | map(select(. != \$id)) | insert_at(\$id; \$index)))
    " --arg folder "$FOLDER_ID" --arg id "$id" --argjson index "$index"
    ;;

  *)
    fail "unknown command: $command"
    ;;
esac
