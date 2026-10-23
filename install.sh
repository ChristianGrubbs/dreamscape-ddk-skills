#!/usr/bin/env bash
# Install the skills in this repo for Codex and/or Claude Code (macOS / Linux / WSL).
#   Codex reads   ~/.agents/skills/<name>   (also scanned: $CODEX_HOME/skills; do not install into both)
#   Claude Code   ~/.claude/skills/<name>
# Usage: ./install.sh [--agent both|codex|claude] [--mode link|copy] [--force] [--uninstall] [--home <dir>]
# link (default) symlinks into this clone so `git pull` updates in place; copy writes a marker file per skill.
# Folders this script did not create are left alone unless --force, which renames them to <name>.bak-<timestamp>.
# Exit 0 = all skills installed/removed; 1 = at least one skipped or failed.
set -u
agent=both; mode=link; force=0; uninstall=0; home="${HOME}"
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) agent="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --force) force=1; shift ;;
    --uninstall) uninstall=1; shift ;;
    --home) home="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$agent" in both|codex|claude) ;; *) echo "--agent must be both|codex|claude" >&2; exit 2 ;; esac
case "$mode" in link|copy) ;; *) echo "--mode must be link|copy" >&2; exit 2 ;; esac
repo="$(cd "$(dirname "$0")" && pwd -P)"
marker=".dreamscape-ddk-skills-install"
log="${TMPDIR:-/tmp}/dreamscape-ddk-skills-install.jsonl"
run_id="$(date +%s)$$"
emit() { printf '{"ts":"%s","run_id":"%s","level":"%s","event":"%s","loc":"install.sh","ctx":{"agent":"%s","skill":"%s","dst":"%s"}}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$run_id" "$1" "$2" "$3" "$4" "$5" >> "$log"; echo "$1 $2 agent=$3 skill=$4 dst=$5"; }
roots=()
[ "$agent" != claude ] && roots+=("codex:$home/.agents/skills")
[ "$agent" != codex ] && roots+=("claude:$home/.claude/skills")
codex_home="${CODEX_HOME:-$home/.codex}"
failed=0
for r in "${roots[@]}"; do
  a="${r%%:*}"; dir="${r#*:}"; mkdir -p "$dir"
  for s in "$repo"/skills/*/; do
    s="${s%/}"; [ -f "$s/SKILL.md" ] || continue
    name="$(basename "$s")"; dst="$dir/$name"
    target=""; [ -L "$dst" ] && target="$(cd "$dst" 2>/dev/null && pwd -P)"
    if [ "$uninstall" = 1 ]; then
      if [ -L "$dst" ] && [ "$target" = "$s" ]; then rm "$dst"; emit info removed_link "$a" "$name" "$dst"
      elif [ -d "$dst" ] && [ -f "$dst/$marker" ]; then rm -rf "$dst"; emit info removed_copy "$a" "$name" "$dst"
      elif [ -e "$dst" ]; then emit warn left_foreign_folder "$a" "$name" "$dst"; failed=1
      else emit info not_installed "$a" "$name" "$dst"; fi
      continue
    fi
    [ "$a" = codex ] && [ -e "$codex_home/skills/$name" ] && emit warn duplicate_in_codex_home "$a" "$name" "$codex_home/skills/$name"
    if [ -L "$dst" ] && [ "$target" = "$s" ] && [ "$mode" = link ]; then emit info already_installed "$a" "$name" "$dst"; continue; fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      if { [ -L "$dst" ] && [ "$target" = "$s" ]; } || [ -f "$dst/$marker" ]; then
        if [ -L "$dst" ]; then rm "$dst"; else rm -rf "$dst"; fi; emit info replacing_previous_install "$a" "$name" "$dst"
      elif [ "$force" = 1 ]; then
        if [ -L "$dst" ]; then rm "$dst"; else mv "$dst" "$dst.bak-$(date +%Y%m%d%H%M%S)"; fi; emit warn moved_foreign "$a" "$name" "$dst"
      else emit error skipped_existing "$a" "$name" "$dst"; failed=1; continue; fi
    fi
    if [ "$mode" = link ]; then ln -s "$s" "$dst"
    else cp -R "$s" "$dst"; find "$dst" -name __pycache__ -type d -prune -exec rm -rf {} +
         printf 'source=%s\ncommit=%s\n' "$s" "$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)" > "$dst/$marker"; fi
    if [ -f "$dst/SKILL.md" ]; then emit info "installed_$mode" "$a" "$name" "$dst"; else emit error install_failed "$a" "$name" "$dst"; failed=1; fi
  done
done
echo "Restart open Codex / Claude Code sessions, then check /skills (Codex: \$dreamscape-ddk-re; Claude: /dreamscape-ddk-re)."
exit $failed
