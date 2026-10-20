#!/usr/bin/env bash
# PreToolUse hook: enforce conventional commit message format.
# Validates that commit messages match: type(scope)?!?: description
# Types kept in sync with claude/scripts/check-commit-format.sh (the CI backstop).
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  exit 0
fi

deny() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Only inspect git commit commands (not amend, merge, rebase). POSIX classes,
# not GNU `\s`: the public settings template enables this hook on macOS too.
if ! grep -qE 'git[[:space:]]+commit[[:space:]]' <<<"$COMMAND"; then
  exit 0
fi

# Skip if --amend (amending existing message)
if grep -qE -- '--amend' <<<"$COMMAND"; then
  exit 0
fi

# Skip if no -m flag (interactive editor — user controls the message)
if ! grep -qE '[[:space:]]-m[[:space:]]' <<<"$COMMAND"; then
  exit 0
fi

# Extract the commit message — handle both heredoc (cat <<) and inline -m "..."
# With POSIX tools only (no `grep -P`, absent from macOS grep). A message that
# cannot be extracted fails closed below, like an invalid one — before, a
# failed extraction was masked and the commit went through unchecked.
# Heredoc only when the -m argument itself is a `$(cat <<…` substitution —
# a literal "cat <<EOF" inside an inline message is just text.
if grep -qE -- "-m[[:space:]]+\"?\\\$\\(cat[[:space:]]+<<" <<<"$COMMAND"; then
  # Heredoc style: git commit -m "$(cat <<'EOF' ... EOF )"
  # Extract content between the heredoc markers
  # `|| MSG=""`: an empty extraction must reach the fail-closed deny below,
  # not end the hook through `set -e` (a hook error lets the commit run).
  # The final awk reads ALL of its input: an early-exiting `head -1` could
  # SIGPIPE its writer under pipefail and wipe a correctly extracted subject.
  MSG=$(printf '%s\n' "$COMMAND" | sed -n "/cat <<.*EOF/,/EOF/p" | grep -v 'cat <<' | grep -v '^[[:space:]]*EOF' \
    | awk 'NF && !d { sub(/^[[:space:]]+/, ""); print; d = 1 }') || MSG=""
else
  # Inline style: the first `-m` argument — "double", 'single' or bare word.
  # The whole command is ONE awk record (RS is a control byte that never
  # appears), so a quoted message whose closing quote sits on a later line —
  # subject, blank line, body — is read whole; its first line is validated.
  MSG=$(printf '%s\n' "$COMMAND" | awk 'BEGIN { RS = "\001" }
    match($0, /[[:space:]]-m[[:space:]]+/) {
      rest = substr($0, RSTART + RLENGTH)
      q = substr(rest, 1, 1)
      if (q == "\"" || q == "\047") {
        rest = substr(rest, 2)
        end = index(rest, q)
        if (end == 0) exit
        print substr(rest, 1, end - 1)
      } else {
        match(rest, /^[^[:space:]]+/)
        if (RLENGTH > 0) print substr(rest, 1, RLENGTH)
      }
      exit
    }') || MSG=""
fi

if [ -z "$MSG" ]; then
  deny "Could not read the commit message from this command to check its conventional-commit format. Pass the subject as -m \"type: description\" (or a -m \"\$(cat <<'EOF' … EOF)\" heredoc)."
fi

# Heredoc-constructed commit bodies frequently open with a blank line before the
# actual subject (e.g. when the heredoc is built by appending sections). Skip
# leading blank/whitespace-only lines
# so the conventional-commit regex check applies to the FIRST NON-BLANK line —
# which is the real subject — instead of erroring on a leading blank.
FIRST_LINE=$(awk 'NF && !d { print; d = 1 }' <<<"$MSG")

# Validate: first non-blank line must match  type(scope)?!?: description
# Type list and subject regex are kept identical to the CI backstop
# claude/scripts/check-commit-format.sh so a message can't pass one gate and
# fail the other. Update both together.
VALID_TYPES="feat|fix|refactor|chore|docs|test|style|perf|build|ci|revert"
SUBJECT_RE="^(${VALID_TYPES})(\([a-z0-9._/-]+\))?!?: .+"
if ! grep -qE "$SUBJECT_RE" <<<"$FIRST_LINE"; then
  deny "Commit message must start with a conventional type: ${VALID_TYPES//|/, } (optionally with (scope) and/or ! before the colon). Got: '$(printf '%s' "$FIRST_LINE" | cut -c1-60)'"
fi

exit 0
