set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if command -v yq >/dev/null 2>&1; then
  while IFS= read -r file; do
    if yq --version 2>&1 | grep -qi 'mikefarah'; then
      yq e '.' "$file" >/dev/null
    else
      yq '.' "$file" >/dev/null
    fi
  done < <(find .github/workflows actions \( -name '*.yml' -o -name '*.yaml' \) | sort)
else
  echo "::warning::yq is not installed; skipping YAML parse validation."
fi

while IFS= read -r file; do
  bash -n "$file"
done < <(find scripts actions tests -name '*.sh' | sort)

echo "Workflow and shell validation passed."
