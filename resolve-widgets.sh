#!/bin/bash
# Resolves bar-widget ids to their QML entry points.
# Usage: resolve-widgets.sh <id>...   ->  JSON array of {id, url, name, builtin}
# Ids starting with `builtin.` are tiles Bar Folder draws itself.
#
# Resolution follows the shell's plugin registry, so hosting a widget in the
# folder never loads code the shell itself would refuse to load:
#   - manifests are validated the same way (schemaVersion, id, kind
#     `bar-widget`, relative entry points without `..`);
#   - plugins listed in `disabledPlugins` are not loaded;
#   - first-party plugins win; third-party plugins cannot claim an
#     `omarchy.*` id or the id of a first-party plugin;
#   - a local clone (omarchy.clonedFrom) only replaces the built-in when that
#     clone is enabled in shell.json or sits in the folder itself.

set -euo pipefail

user_dir="$HOME/.config/omarchy/plugins"
system_dir="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins"
config_file="$HOME/.config/omarchy/shell.json"
folder_id="io.github.arikisonfire.bar-folder"

emit() {
  local kind=$1 file=$2
  jq -c --arg dir "$(dirname -- "$file")" --arg kind "$kind" '
    def safe_entry: type == "string" and length > 0
      and (startswith("/") | not) and (contains("..") | not);
    select(type == "object"
      and .schemaVersion == 1
      and (.id | type == "string" and length > 0 and (contains("/") | not) and (contains("..") | not))
      and .name != null and .version != null
      and (.kinds | type == "array" and index("bar-widget") != null)
      and (.entryPoints | type == "object" and ([.[] | safe_entry] | all))
      and (.entryPoints.barWidget | type == "string"))
    | {
        id,
        firstParty: ($kind == "firstparty"),
        clonedFrom: ((.omarchy | objects | .clonedFrom | strings) // ""),
        name: ((.barWidget | objects | .displayName | strings) // (.name | tostring)),
        path: ($dir + "/" + .entryPoints.barWidget)
      }' "$file" 2>/dev/null || true
}

catalog=$(
  {
    if [[ -d $system_dir ]]; then
      find "$system_dir" -mindepth 2 -maxdepth 3 -type f \( -name manifest.json -o -name '*.manifest.json' \) -print0 2>/dev/null \
        | sort -z | while IFS= read -r -d '' file; do emit firstparty "$file"; done
    fi
    for file in "$user_dir"/*/manifest.json; do
      if [[ -f $file ]]; then emit thirdparty "$file"; fi
    done
  } | jq -s '
    (map(select(.firstParty) | .id) | unique) as $first
    | map(select(.firstParty or ((.id | startswith("omarchy.") | not) and (.id | IN($first[]) | not))))'
)

config='{}'
if [[ -s $config_file ]]; then
  config=$(jq -c 'if type == "object" then . else {} end' "$config_file" 2>/dev/null || echo '{}')
fi

# Ids travel as one JSON value, never as jq command-line arguments.
ids=$(if (($#)); then printf '%s\n' "$@"; fi | jq -R . | jq -s -c 'map(select(. != ""))')

jq -n --argjson catalog "$catalog" --argjson config "$config" --argjson ids "$ids" --arg folder "$folder_id" '
  def entry_id: if type == "object" then (.id // "" | tostring) else tostring end;
  def valid_id: test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not);
  def file_url: "file://" + (split("/") | map(@uri) | join("/"));
  {"builtin.notifications": "Notifications"} as $builtins
  | ([($config.bar | objects | .layout | objects | .[] | arrays | .[] | entry_id),
      ($config.plugins | arrays | .[] | entry_id),
      ($config.bar | objects | .id | strings)] | map(select(. != ""))) as $referenced
  | (($config.disabledPlugins | arrays) // []) as $disabled
  | ($referenced + $ids) as $active
  | [$ids[] as $id
     | if $builtins[$id] then {id: $id, url: "", name: $builtins[$id], builtin: true}
       elif ($id | valid_id | not) or $id == $folder then {id: $id, url: "", name: $id, builtin: false}
       else
         # Same precedence as the registry: an enabled clone first, then the
         # last manifest registered under that id (first-party before third-party).
         ([$catalog[] | select((.firstParty | not) and .clonedFrom == $id
                               and (.id | IN($active[])) and (.id | IN($disabled[]) | not))][0]
          // (if $id | IN($disabled[]) then null
              else ([$catalog[] | select(.id == $id and .firstParty)] | last)
                // ([$catalog[] | select(.id == $id and (.firstParty | not))] | last)
              end)) as $hit
         | if $hit
           then {id: $id, url: ($hit.path | file_url), name: $hit.name, builtin: false}
           else {id: $id, url: "", name: $id, builtin: false}
           end
       end]
'
