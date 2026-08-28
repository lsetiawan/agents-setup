#!/bin/bash

set -e

ASSUME_YES=0
HARNESS=""

usage() {
  echo "Usage: $0 [harness] [-y|--yes]"
  echo ""
  echo "Deletes running incus containers, listing them and asking for"
  echo "confirmation first unless -y/--yes is passed."
  echo ""
  echo "  harness   only delete containers for this harness, matched on the"
  echo "            '<harness>--' name prefix the launchers use (e.g. claude,"
  echo "            and copilot/opencode/codex as they are added). Omit it to"
  echo "            delete every running container, including ones not created"
  echo "            by this repo."
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown option '$1'. See --help." >&2
      exit 1
      ;;
    *)
      if [ -n "$HARNESS" ]; then
        echo "Error: only one harness can be given (got '$HARNESS' and '$1')." >&2
        exit 1
      fi
      HARNESS="$1"
      ;;
  esac
  shift
done

# Launchers name containers '<harness>--<directory>-<hash>'.
PREFIX=""
if [ -n "$HARNESS" ]; then
  PREFIX="${HARNESS}--"
fi

ALL_RUNNING=$(incus list --format csv -c ns | awk -F, 'tolower($2) == "running" { print $1 }')
RUNNING=$(echo "$ALL_RUNNING" | awk -v prefix="$PREFIX" 'NF && (prefix == "" || index($0, prefix) == 1)')

if [ -z "$RUNNING" ]; then
  if [ -n "$HARNESS" ]; then
    echo "No running $HARNESS containers."
    if [ -n "$ALL_RUNNING" ]; then
      echo "Running containers for other harnesses:"
      echo "$ALL_RUNNING" | sed -e 's/^/  /'
    fi
  else
    echo "No running containers."
  fi
  exit 0
fi

echo "The following running containers will be deleted:"
echo "$RUNNING" | sed -e 's/^/  /'

if [ "$ASSUME_YES" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "Error: not running interactively; re-run with --yes to confirm." >&2
    exit 1
  fi

  printf 'Delete them? [y/N] '
  read -r REPLY
  case "$REPLY" in
    y|Y|yes|Yes|YES) ;;
    *)
      echo "Aborted; nothing was deleted."
      exit 1
      ;;
  esac
fi

echo "$RUNNING" | while IFS= read -r name; do
  [ -n "$name" ] || continue
  echo "Deleting $name"
  incus delete --force "$name"
done
