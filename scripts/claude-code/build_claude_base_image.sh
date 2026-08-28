#!/bin/bash

set -e

IMG_ALIAS="claude-base-image"
BUILD_BOX="builder"
LINUX_IMG="images:alpine/3.24"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_TEMPLATE="$SCRIPT_DIR/claude-settings.json"
SETUP_SCRIPT="$SCRIPT_DIR/setup_claude_base_image.sh"

# Launch builder
incus launch "$LINUX_IMG" "$BUILD_BOX"

# Wait for the network (interface + DNS/TLS) to actually be ready
for i in $(seq 1 30); do
	if incus exec "$BUILD_BOX" -- sh -c 'wget -q -T 2 -O /dev/null https://dl-cdn.alpinelinux.org' 2>/dev/null; then
		break
	fi
	sleep 1
done

# Push and run the provisioning script
incus file push "$SETUP_SCRIPT" "$BUILD_BOX/root/setup.sh"
incus exec "$BUILD_BOX" -- sh /root/setup.sh
incus exec "$BUILD_BOX" -- rm /root/setup.sh

# Add claude configs from template file
incus file push "$LOCAL_TEMPLATE" "$BUILD_BOX/root/.claude/settings.json"

# Freeze into your native local image registry and clean up
incus stop "$BUILD_BOX"
incus publish "$BUILD_BOX" --alias "$IMG_ALIAS" --reuse
incus delete "$BUILD_BOX"
