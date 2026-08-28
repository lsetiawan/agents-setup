#!/bin/sh

set -e

# Update and provision system dependencies
apk update
apk add --no-cache curl ca-certificates git bash

# Install Claude Code headlessly
curl -fsSL https://claude.ai/install.sh | bash

# Prepare the configuration folder layout
mkdir -p /root/.claude/
# Create symlink to global bin
ln -s /root/.local/bin/claude /usr/bin/claude
