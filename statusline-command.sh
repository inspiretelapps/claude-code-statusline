#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract basic info
project_dir=$(echo "$input" | jq -r '.workspace.project_dir')
repo_name=$(basename "$project_dir")
model=$(echo "$input" | jq -r '.model.display_name')

# Fetch API usage from Anthropic (cached)
CACHE_FILE="/tmp/claude-usage-cache.json"
CACHE_MAX_AGE=60

TOKEN_CACHE_FILE="/tmp/claude-oauth-token-cache.json"
TOKEN_CACHE_MAX_AGE=3600

get_access_token() {
  # Check token cache first (refreshed tokens are cached here)
  if [ -f "$TOKEN_CACHE_FILE" ]; then
    token_cache_age=$(($(date +%s) - $(stat -f %m "$TOKEN_CACHE_FILE" 2>/dev/null || echo 0)))
    if [ $token_cache_age -lt $TOKEN_CACHE_MAX_AGE ]; then
      cached_token=$(jq -r '.access_token // empty' "$TOKEN_CACHE_FILE" 2>/dev/null)
      if [ -n "$cached_token" ]; then
        echo "$cached_token"
        return
      fi
    fi
  fi

  # Read credentials from Keychain - try current user account first, then fallback
  local acct
  acct=$(whoami)
  creds=$(security find-generic-password -s "Claude Code-credentials" -a "$acct" -w 2>/dev/null)
  if [ -z "$creds" ] || ! echo "$creds" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  fi

  access_token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  refresh_token=$(echo "$creds" | jq -r '.claudeAiOauth.refreshToken // empty' 2>/dev/null)
  expires_at=$(echo "$creds" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null)
  now_ms=$(($(date +%s) * 1000))

  # If token is still valid, use it
  if [ -n "$access_token" ] && [ "$now_ms" -lt "$expires_at" ] 2>/dev/null; then
    echo "$access_token"
    return
  fi

  # Token expired - refresh it
  if [ -n "$refresh_token" ]; then
    refresh_result=$(curl -s -X POST "https://platform.claude.com/v1/oauth/token" \
      -H "Content-Type: application/json" \
      -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$refresh_token\",\"client_id\":\"9d1c250a-e61b-44d9-88ed-5944d1962f5e\",\"scope\":\"user:profile user:inference user:sessions:claude_code user:mcp_servers\"}" 2>/dev/null)

    new_token=$(echo "$refresh_result" | jq -r '.access_token // empty' 2>/dev/null)
    if [ -n "$new_token" ]; then
      # Cache the refreshed token
      echo "$refresh_result" > "$TOKEN_CACHE_FILE"

      # Update Keychain with new credentials
      new_refresh=$(echo "$refresh_result" | jq -r '.refresh_token // empty' 2>/dev/null)
      expires_in=$(echo "$refresh_result" | jq -r '.expires_in // 0' 2>/dev/null)
      new_expires_at=$(( $(date +%s) * 1000 + expires_in * 1000 ))
      [ -z "$new_refresh" ] && new_refresh="$refresh_token"
      updated_creds=$(echo "$creds" | jq --arg at "$new_token" --arg rt "$new_refresh" --argjson ea "$new_expires_at" \
        '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $ea')
      security delete-generic-password -s "Claude Code-credentials" -a "$acct" >/dev/null 2>&1
      security add-generic-password -s "Claude Code-credentials" -a "$acct" -w "$updated_creds" 2>/dev/null

      echo "$new_token"
      return
    fi
  fi
}

fetch_usage() {
  token=$(get_access_token)
  if [ -n "$token" ]; then
    curl -s \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-code/2.0.76" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null
  fi
}

# Check cache age
if [ -f "$CACHE_FILE" ]; then
  cache_age=$(($(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)))
  if [ $cache_age -lt $CACHE_MAX_AGE ]; then
    api_usage=$(cat "$CACHE_FILE")
  fi
fi

# Fetch fresh if no cache
if [ -z "$api_usage" ]; then
  api_usage=$(fetch_usage)
  if [ -n "$api_usage" ] && echo "$api_usage" | jq -e '.five_hour' >/dev/null 2>&1; then
    echo "$api_usage" > "$CACHE_FILE"
  fi
fi

# Parse API usage - handle both old and new API response formats
five_hour_pct=$(echo "$api_usage" | jq -r '.five_hour.utilization // 0' 2>/dev/null | cut -d. -f1)
seven_day_pct=$(echo "$api_usage" | jq -r '.seven_day.utilization // 0' 2>/dev/null | cut -d. -f1)
# Try seven_day_opus first, fall back to seven_day_sonnet
opus_pct=$(echo "$api_usage" | jq -r '(.seven_day_opus.utilization // .seven_day_sonnet.utilization // 0)' 2>/dev/null | cut -d. -f1)

# Determine label for model-specific limit
if echo "$api_usage" | jq -e '.seven_day_opus.utilization' >/dev/null 2>&1; then
  model_limit_label="Opus"
elif echo "$api_usage" | jq -e '.seven_day_sonnet.utilization' >/dev/null 2>&1; then
  model_limit_label="Sonnet"
else
  model_limit_label="Model"
fi

# Get git branch
cd "$project_dir" 2>/dev/null
branch=$(git -c core.useReplaceRefs=false branch --show-current 2>/dev/null || echo "no-git")

# Calculate context window usage percentage
usage=$(echo "$input" | jq '.context_window.current_usage')
if [ "$usage" != "null" ] && [ -n "$usage" ]; then
  current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
  size=$(echo "$input" | jq '.context_window.context_window_size')
  if [ "$size" != "null" ] && [ "$size" -gt 0 ] 2>/dev/null; then
    pct=$((current * 100 / size))
  else
    pct=0
  fi

  # Create progress bar
  bar_width=10
  filled=$((pct * bar_width / 100))
  unfilled=$((bar_width - filled))
  filled_bar=""
  unfilled_bar=""
  for i in $(seq 1 $filled); do filled_bar="${filled_bar}█"; done
  for i in $(seq 1 $unfilled); do unfilled_bar="${unfilled_bar}░"; done

  context_display="\033[37m${filled_bar}\033[2m${unfilled_bar}\033[0m ${pct}%"
else
  context_display="░░░░░░░░░░ 0%"
fi

# Calculate session usage (total tokens)
total_input=$(echo "$input" | jq '.context_window.total_input_tokens // 0')
total_output=$(echo "$input" | jq '.context_window.total_output_tokens // 0')
session_total=$((total_input + total_output))

# Format with K/M suffix for readability
if [ $session_total -ge 1000000 ]; then
  session_display=$(awk "BEGIN {printf \"%.1fM\", $session_total/1000000}")
elif [ $session_total -ge 1000 ]; then
  session_display=$(awk "BEGIN {printf \"%.1fK\", $session_total/1000}")
else
  session_display="${session_total}"
fi

# Color code usage percentages (green < 60, yellow 60-89, red >= 90)
color_pct() {
  local pct=$1
  if [ -z "$pct" ] || [ "$pct" = "0" ]; then
    echo "\033[32m${pct}%\033[0m"  # green
  elif [ "$pct" -ge 90 ] 2>/dev/null; then
    echo "\033[31m${pct}%\033[0m"  # red
  elif [ "$pct" -ge 60 ] 2>/dev/null; then
    echo "\033[33m${pct}%\033[0m"  # yellow
  else
    echo "\033[32m${pct}%\033[0m"  # green
  fi
}

five_hour_display=$(color_pct "$five_hour_pct")
seven_day_display=$(color_pct "$seven_day_pct")
opus_display=$(color_pct "$opus_pct")

# Output status line with clear labels
# Format: repo | model | Context [bar] % | Tokens: N | Limits: 5hr% 7day% Model% | (branch)
printf "\033[33m%s\033[0m | %s | Context %b | Tokens: \033[36m%s\033[0m | Limits: 5hr %b · 7day %b · %s %b | (\033[32m%s\033[0m)" \
  "$repo_name" \
  "$model" \
  "$context_display" \
  "$session_display" \
  "$five_hour_display" \
  "$seven_day_display" \
  "$model_limit_label" \
  "$opus_display" \
  "$branch"
