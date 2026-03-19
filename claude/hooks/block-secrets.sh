#!/usr/bin/env bash
# PreToolUse hook: prevent accidentally staging files that likely contain secrets.
# Registered in settings.json for Bash tool calls.
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

# Only inspect git add and git commit commands
if ! echo "$COMMAND" | grep -qE 'git\s+(add|commit)'; then
  exit 0
fi

# Block staging known secret files
SECRET_FILES='\.(env|env\.local|env\.prod|env\.production|env\.staging|env\.development)(\..*)?$'
SECRET_FILES="$SECRET_FILES|credentials\.json|service.account\.json|\.pem$|\.key$|\.p12$|\.pfx$"
SECRET_FILES="$SECRET_FILES|\.npmrc$|\.pypirc$|\.netrc$|\.docker/config\.json"
SECRET_FILES="$SECRET_FILES|id_rsa|id_ed25519|id_ecdsa"

if echo "$COMMAND" | grep -qE 'git\s+add'; then
  # Extract file arguments after "git add" (skip flags)
  FILES=$(echo "$COMMAND" | sed 's/.*git\s\+add\s*//' | tr ' ' '\n' | grep -v '^-' || true)
  for f in $FILES; do
    if echo "$f" | grep -qiE "$SECRET_FILES"; then
      deny "Refusing to stage '$f' — looks like a secret/credential file. If intentional, stage it manually."
    fi
  done
  # Block "git add -A" or "git add ." which could sweep in secrets
  if echo "$COMMAND" | grep -qE 'git\s+add\s+(-A|--all|\.)'; then
    deny "Use 'git add <specific files>' instead of 'git add -A' or 'git add .' to avoid accidentally staging secrets."
  fi
fi

# Scan for inline secrets in commit message (API keys, tokens)
if echo "$COMMAND" | grep -qE 'git\s+commit'; then
  # Check if commit message contains what looks like an API key or token
  MSG=$(echo "$COMMAND" | grep -oP '(?<=-m\s["\x27]).*?(?=["\x27])' || true)
  if echo "$MSG" | grep -qiE '(sk-[a-zA-Z0-9]{20,}|AKIA[A-Z0-9]{16}|ghp_[a-zA-Z0-9]{36}|glpat-[a-zA-Z0-9-]{20,})'; then
    deny "Commit message appears to contain an API key or token. Remove it before committing."
  fi
fi

exit 0
