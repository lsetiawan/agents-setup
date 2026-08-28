if ! command -v colima >/dev/null 2>&1; then
  echo "Error: Colima ('colima') is required but was not found on PATH." >&2
  echo "Install it: see https://colima.run/#quick-start" >&2
  exit 1
fi
