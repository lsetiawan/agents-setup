#!/bin/bash

set -e

IMG_ALIAS="copilot-base-image"
BUILD_BOX="builder"
LINUX_IMG="images:alpine/3.24"

# Launch builder
incus launch "$LINUX_IMG" "$BUILD_BOX"

# Wait for the network interface to be up
sleep 3

incus exec "$BUILD_BOX" -- sh << EOF
	# Update and provision system dependencies
	apk update
	apk add --no-cache curl ca-certificates git bash coreutils

	# Install Copilot
  curl -fsSL https://gh.io/copilot-install | bash
EOF

# Freeze into your native local image registry and clean up
incus stop "$BUILD_BOX"
incus publish "$BUILD_BOX" --alias "$IMG_ALIAS" --reuse
incus delete "$BUILD_BOX"
