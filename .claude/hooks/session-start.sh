#!/bin/bash
# Installs the Firecrawl CLI skills so web sessions can use Firecrawl right away.
set -euo pipefail

# Only needed in Claude Code on the web; local setups keep their own install.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Run in the background so the session does not wait for the install.
echo '{"async": true, "asyncTimeout": 300000}'

SKILL_DIR="${HOME}/.claude/skills/firecrawl"

if [ -d "$SKILL_DIR" ]; then
  echo "Firecrawl skills already installed - skipping init."
else
  # The installer only detects Claude Code when this directory exists.
  mkdir -p "${HOME}/.claude"
  npx -y firecrawl-cli@latest init -y --agent claude-code --skip-auth --skip-install
fi

if [ -n "${FIRECRAWL_API_KEY:-}" ]; then
  echo "FIRECRAWL_API_KEY is set - Firecrawl is authenticated."
else
  echo "FIRECRAWL_API_KEY is not set - Firecrawl runs on the rate-limited keyless tier."
  echo "Add the key as an environment variable in the Claude Code environment settings."
fi
