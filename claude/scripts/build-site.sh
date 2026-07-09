#!/usr/bin/env bash
# build-site.sh — generate the GitHub Pages site sources (issue #168).
#
# Populates the gitignored site-src/ directory that mkdocs.yml uses as its
# docs_dir. Nothing under site-src/ is hand-maintained or committed — the
# site is GENERATED, NOT WRITTEN (the .doc-contract tier for it):
#
#   1. Copies the existing top-level docs (README, CLAUDE-GUIDE,
#      claude/MULTI-AGENT, docs/WINDOWS, docs/BRANCH_PROTECTION) into
#      site-src/, rewriting relative links so `mkdocs build --strict`
#      passes: links between the copied pages become site-page links,
#      links to any other repo path become absolute GitHub URLs.
#   2. Generates the skill and agent catalog pages from the live
#      frontmatter of claude/skills/*/SKILL.md and claude/agents/*.md,
#      so the catalog can't drift from the source of truth.
#
# A copy step (not symlinks into docs_dir) is used deliberately: the copied
# pages need link rewriting anyway, and symlinks are fragile on the Windows
# checkouts this repo supports (docs/WINDOWS.md).
#
# Usage:  claude/scripts/build-site.sh      (then: mkdocs build --strict)
# Deps:   bash + git + awk + coreutils — no network, no package installs.

set -euo pipefail

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "✖ build-site: not inside a git repository" >&2
  exit 1
fi
cd "$REPO_ROOT" || exit 1

GITHUB_BASE="https://github.com/jckeen/dotfiles"
OUT="site-src"

# Repo path → site page. Keep in sync with the nav in mkdocs.yml.
PAGE_MAP="README.md=index.md;CLAUDE-GUIDE.md=guide.md;claude/MULTI-AGENT.md=multi-agent.md;docs/WINDOWS.md=windows.md;docs/BRANCH_PROTECTION.md=branch-protection.md"

rm -rf "$OUT"
mkdir -p "$OUT"

generated_banner() { # src-path
  printf '<!-- GENERATED from %s by claude/scripts/build-site.sh — do not edit. -->\n\n' "$1"
}

# ── 1. Copy existing docs, rewriting relative links ────────────────
# Fence-aware: lines inside ``` / ~~~ blocks pass through untouched.
copy_page() { # src-repo-path
  local src="$1" dest srcdir
  dest="${PAGE_MAP#*"$src"=}"
  dest="${dest%%;*}"
  srcdir="$(dirname "$src")"
  {
    generated_banner "$src"
    awk -v srcdir="$srcdir" -v map_str="$PAGE_MAP" -v gh="$GITHUB_BASE" '
      function normalize(path,    parts, n, i, stack, top, out, trail) {
        trail = (path ~ /\/$/) ? "/" : ""
        n = split(path, parts, "/")
        top = 0
        for (i = 1; i <= n; i++) {
          if (parts[i] == "" || parts[i] == ".") continue
          if (parts[i] == "..") { if (top > 0) top--; continue }
          stack[++top] = parts[i]
        }
        out = ""
        for (i = 1; i <= top; i++) out = out (i > 1 ? "/" : "") stack[i]
        return out trail
      }
      function rewrite(target,    frag, path, resolved, hashpos) {
        if (target ~ /^(https?:|mailto:|#|\/|<)/) return target
        hashpos = index(target, "#")
        if (hashpos > 0) {
          frag = substr(target, hashpos)
          path = substr(target, 1, hashpos - 1)
        } else { frag = ""; path = target }
        if (path == "") return target
        resolved = normalize(srcdir "/" path)
        if (resolved in map) return map[resolved] frag
        if (resolved ~ /\/$/) return gh "/tree/main/" resolved
        return gh "/blob/main/" resolved frag
      }
      BEGIN {
        n = split(map_str, pairs, ";")
        for (i = 1; i <= n; i++) {
          eq = index(pairs[i], "=")
          map[substr(pairs[i], 1, eq - 1)] = substr(pairs[i], eq + 1)
        }
      }
      /^[[:space:]]*(```|~~~)/ { infence = !infence; print; next }
      infence { print; next }
      {
        line = $0
        out = ""
        while (match(line, /\]\([^)]+\)/)) {
          target = substr(line, RSTART + 2, RLENGTH - 3)
          out = out substr(line, 1, RSTART + 1) rewrite(target) ")"
          line = substr(line, RSTART + RLENGTH)
        }
        print out line
      }
    ' "$src"
  } > "$OUT/$dest"
  echo "  $src → $OUT/$dest"
}

echo "build-site: copying existing docs"
copy_page "README.md"
copy_page "CLAUDE-GUIDE.md"
copy_page "claude/MULTI-AGENT.md"
copy_page "docs/WINDOWS.md"
copy_page "docs/BRANCH_PROTECTION.md"

# ── 2. Generate the catalogs from live frontmatter ─────────────────
# Emits KEY<TAB>VALUE lines for the frontmatter block of one file.
# Handles `key: value` and folded/literal block scalars (`key: >-` etc.).
read_frontmatter() { # file
  awk '
    NR == 1 { if ($0 ~ /^---[[:space:]]*$/) { fm = 1; next } else exit }
    !fm { exit }
    /^---[[:space:]]*$/ { exit }
    /^[A-Za-z][A-Za-z0-9_-]*:/ {
      key = $0; sub(/:.*$/, "", key)
      val = $0; sub(/^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*/, "", val)
      if (val ~ /^[>|][+-]?[[:space:]]*$/) { block = 1; curkey = key; vals[key] = "" }
      else { block = 0; vals[key] = val }
      next
    }
    block && /^[[:space:]]+[^[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      vals[curkey] = vals[curkey] (vals[curkey] == "" ? "" : " ") line
      next
    }
    { block = 0 }
    END { for (k in vals) printf "%s\t%s\n", k, vals[k] }
  ' "$1"
}

fm_get() { # key frontmatter-text
  awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' <<<"$2"
}

echo "build-site: generating skill catalog"
{
  generated_banner "claude/skills/*/SKILL.md frontmatter"
  echo "# Skill catalog"
  echo ""
  echo "Slash-command skills shipped by these dotfiles, generated from the live"
  echo "frontmatter of each \`claude/skills/<name>/SKILL.md\` at build time —"
  echo "this page cannot drift from the source. Invoke a skill as \`/<name>\`."
  count=0
  for f in claude/skills/*/SKILL.md; do
    fm="$(read_frontmatter "$f")"
    name="$(fm_get name "$fm")"
    desc="$(fm_get description "$fm")"
    manual="$(fm_get disable-model-invocation "$fm")"
    [[ -n "$name" ]] || { echo "✖ build-site: no name in $f frontmatter" >&2; exit 1; }
    count=$((count + 1))
    echo ""
    echo "## \`/$name\`"
    echo ""
    echo "$desc"
    echo ""
    if [[ "$manual" == "true" ]]; then
      echo "*Manual-only: invoked explicitly by the user, never auto-triggered.*"
      echo ""
    fi
    echo "Source: [\`$f\`]($GITHUB_BASE/blob/main/$f)"
  done
  echo ""
  echo "---"
  echo ""
  echo "*$count skills, enumerated at build time.*"
} > "$OUT/skills.md"
echo "  → $OUT/skills.md"

echo "build-site: generating agent catalog"
{
  generated_banner "claude/agents/*.md frontmatter"
  echo "# Agent catalog"
  echo ""
  echo "Subagents shipped by these dotfiles, generated from the live frontmatter"
  echo "of each \`claude/agents/<name>.md\` at build time — this page cannot"
  echo "drift from the source."
  count=0
  for f in claude/agents/*.md; do
    fm="$(read_frontmatter "$f")"
    name="$(fm_get name "$fm")"
    desc="$(fm_get description "$fm")"
    tools="$(fm_get tools "$fm")"
    [[ -n "$name" ]] || { echo "✖ build-site: no name in $f frontmatter" >&2; exit 1; }
    count=$((count + 1))
    echo ""
    echo "## \`$name\`"
    echo ""
    echo "$desc"
    echo ""
    [[ -n "$tools" ]] && echo "**Tools:** $tools"
    echo ""
    echo "Source: [\`$f\`]($GITHUB_BASE/blob/main/$f)"
  done
  echo ""
  echo "---"
  echo ""
  echo "*$count agents, enumerated at build time.*"
} > "$OUT/agents.md"
echo "  → $OUT/agents.md"

echo "build-site: OK — sources in $OUT/ (next: mkdocs build --strict)"
