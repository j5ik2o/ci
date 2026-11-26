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

# The workflow and action defaults override the script's, so all three must agree.
eval "$(grep '^DEFAULT_IGNORED_AUTO_REPORT_' scripts/review-thread-resolution.sh)"
DEFAULT_IGNORED_AUTO_REPORT_PATTERNS="$DEFAULT_IGNORED_AUTO_REPORT_PATTERNS" \
DEFAULT_IGNORED_AUTO_REPORT_AUTHOR_PATTERNS="$DEFAULT_IGNORED_AUTO_REPORT_AUTHOR_PATTERNS" \
ruby -ryaml -e '
  {
    ".github/workflows/review-thread-resolution.yml" => ->(doc) { (doc["on"] || doc[true])["workflow_call"]["inputs"] },
    "actions/review-thread-resolution/action.yml" => ->(doc) { doc["inputs"] },
  }.each do |file, inputs_of|
    inputs = inputs_of.(YAML.load_file(file))
    %w[ignored_auto_report_patterns ignored_auto_report_author_patterns].each do |name|
      expected = ENV.fetch("DEFAULT_#{name.upcase}")
      actual = inputs.fetch(name).fetch("default").chomp
      abort "#{file}: the #{name} default differs from scripts/review-thread-resolution.sh." unless actual == expected
    end
  end
'

node --test --test-reporter=spec actions/takt-review-wrapper/default/*.test.mjs

echo "Workflow and shell validation passed."
