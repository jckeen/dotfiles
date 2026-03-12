#!/usr/bin/env bash
input=$(cat)
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used" ]; then
  printf "Context: %s%%" "$used"
fi
