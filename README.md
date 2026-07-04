# Claude Code Statusline

A custom statusline script for Claude Code on macOS that displays useful session and API usage information.

## Screenshot

![Example statusline](example.png)

## What It Displays

- **Repository name** - Current project directory name
- **Model** - Active Claude model and effort level (e.g., "Opus (medium)")
- **Context window** - Visual progress bar with percentage
- **Session tokens** - Total tokens used this session (formatted as K/M)
- **Usage remaining** - 5-hour and 7-day quota left (color-coded: green >40% left, yellow 11-40%, red ≤10%)
- **Git branch** - Current branch name

## Requirements

- macOS (uses Keychain for OAuth token)
- `jq` - Install with `brew install jq`
- Claude Code with OAuth authentication

## Installation

### With AI Agent

Copy and paste this prompt into Claude Code:

```
Use the statusline-setup agent to download and install this script:
https://raw.githubusercontent.com/robinebers/claude-code-statusline/main/statusline-command.sh
```

### Manual Install

1. Copy the script to your Claude directory:

```bash
mkdir -p ~/.claude
curl -o ~/.claude/statusline-command.sh https://raw.githubusercontent.com/robinebers/claude-code-statusline/main/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
```

2. Add to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-command.sh"
  }
}
```

3. Restart Claude Code to see the statusline.

## How It Works

The script receives JSON on stdin from Claude Code containing:
- Workspace info (project directory)
- Model info and effort level
- Context window usage and size
- Session token counts
- Rate limit usage (Claude Code v2.1+)

On Claude Code v2.1+ the rate limits come straight from that stdin JSON, so no network call is needed. On older versions the script falls back to fetching usage from Anthropic's OAuth endpoint using credentials stored in macOS Keychain, with a 60-second cache to avoid excessive API calls.
