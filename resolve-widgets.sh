#!/bin/bash
# Resolves bar-widget ids to their QML entry points.
# Usage: resolve-widgets.sh <id>...   ->  JSON array of {id, url, name, builtin}
# A local clone (omarchy.clonedFrom) wins over the built-in it replaces,
# matching how the shell routes calls to an enabled clone. Ids starting with
# `builtin.` are tiles Bar Folder draws itself.

set -euo pipefail

user_dir="$HOME/.config/omarchy/plugins"
system_dir="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins"

manifests() {
  find "$user_dir" -mindepth 2 -maxdepth 2 -name manifest.json 2>/dev/null || true
  find "$system_dir" \( -name manifest.json -o -name '*.manifest.json' \) 2>/dev/null || true
}

catalog=$(
  manifests | while IFS= read -r file; do
    user=0
    [[ $file == "$user_dir"/* ]] && user=1
    jq -c --arg dir "$(dirname "$file")" --arg user "$user" '
      select(.entryPoints.barWidget? | type == "string")
      | {
          id,
          clonedFrom: (.omarchy.clonedFrom // ""),
          user: ($user == "1"),
          name: (.barWidget.displayName // .name // .id),
          path: ($dir + "/" + .entryPoints.barWidget)
        }' "$file" 2>/dev/null || true
  done | jq -s '.'
)

jq -n --argjson catalog "$catalog" '
  {"builtin.notifications": "Notifications"} as $builtins
  | [$ARGS.positional[] as $id
     | if $builtins[$id] then {id: $id, url: "", name: $builtins[$id], builtin: true}
       else
         ([$catalog[] | select(.user and .clonedFrom == $id)][0]
          // [$catalog[] | select(.id == $id)][0]) as $hit
         | if $hit and ($hit.path | contains("/../") | not)
           then {id: $id, url: ("file://" + $hit.path), name: $hit.name, builtin: false}
           else {id: $id, url: "", name: $id, builtin: false}
           end
       end]
' --args "$@"
