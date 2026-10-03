# Run using bin/ci

CI.run do
  step "Workspace: duplicate files", "bin/check_duplicate_files"

  step "Setup: Ruby dependencies", "bundle check"
  step "Setup: JavaScript dependencies", "npm ci"
  step "Setup: Test database", "bin/rails db:test:prepare"
  step "Setup: Test assets", "bin/rails tailwindcss:build"

  step "Style: Ruby", "bash", "-o", "pipefail", "-c",
       "git ls-files -z | xargs -0 bin/rubocop --force-exclusion --only-recognized-file-types"
  step "Style: JavaScript", "npm run lint:js"
  step "Syntax: JavaScript", 'for file in app/javascript/controllers/*.js; do node --check "$file" || exit 1; done'
  step "Style: CSS", 'npx stylelint "app/assets/tailwind/**/*.css"'
  step "Tests: CSS lint configuration", "npm run test:stylelint"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Tests: Zeitwerk autoloading", "bundle exec rails zeitwerk:check"
  step "Tests: Generated receipt fixtures", "ruby bin/generated_receipts_validate"
  step "Tests: RSpec including system specs", "env -u SPEC_OPTS -u RSPEC_OPTS bundle exec rspec --options /dev/null --require spec_helper"
  step "Tests: Minitest", "bin/rails test"
end
