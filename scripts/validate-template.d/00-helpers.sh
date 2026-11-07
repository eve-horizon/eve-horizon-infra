# shellcheck shell=bash
# Helpers for the render assertions in this directory. Sourced by
# scripts/validate-template.sh after every overlay has been rendered to
# "$work_root/<overlay>.yaml"; each check file may use fail, OVERLAYS and
# work_root from there.

# rendered_doc KIND NAME FILE
# Print the document of FILE (kustomize output) whose top-level kind is KIND
# and metadata.name is NAME. Prints nothing when there is no such document.
rendered_doc() {
  awk -v kind="$1" -v name="$2" '
    function flush() {
      if (doc_kind == kind && doc_name == name) printf "%s", doc
      doc = ""; doc_kind = ""; doc_name = ""; in_meta = 0
    }
    /^---$/ { flush(); next }
    { doc = doc $0 "\n" }
    /^kind: / { doc_kind = $2 }
    /^metadata:$/ { in_meta = 1; next }
    /^[^ ]/ { in_meta = 0 }
    in_meta && /^  name: / && doc_name == "" { doc_name = $2 }
    END { flush() }
  ' "$3"
}

# env_value NAME < DOC
# Print the literal value of the first container env var NAME in DOC.
env_value() {
  awk -v name="$1" '
    $0 ~ ("^ *- name: " name "$") { want = 1; next }
    want && $1 == "value:" { sub(/^ *value: */, ""); gsub(/^"|"$/, ""); print; exit }
    { want = 0 }
  '
}
