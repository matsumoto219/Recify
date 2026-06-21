source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.2"
ruby "4.0.5"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use pg as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Tailwind CSS for Rails
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"
# 外部API HTTPクライアント [https://github.com/lostisland/faraday]
gem "faraday"
# Pagination [https://github.com/ddnexus/pagy]
gem "pagy"
# リクエスト制限ミドルウェア [https://github.com/rack/rack-attack]
gem "rack-attack", "~> 6.8"
# Passkey/WebAuthn検証 [https://github.com/cedarcode/webauthn-ruby]
gem "webauthn", "~> 3.4"
# TOTP生成・検証 [https://github.com/mdp/rotp]
gem "rotp", "~> 6.3"
# QRコード生成 [https://github.com/whomwah/rqrcode]
gem "rqrcode", "~> 3.2"
# Sentry Ruby SDK [https://github.com/getsentry/sentry-ruby]
gem "sentry-ruby", "~> 6.5"
# Sentry Rails連携 [https://github.com/getsentry/sentry-ruby]
gem "sentry-rails", "~> 6.5"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.0"
gem "ruby-vips", "~> 2.3", require: false

# Rails標準文言の日本語化 [https://github.com/svenfuchs/rails-i18n]
gem "rails-i18n"

group :development, :test do
  gem "dotenv-rails"

  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
  gem "rspec-rails"
  gem "factory_bot_rails"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Preview delivered emails in the browser during development
  gem "letter_opener_web"

  # HTML lint
  # Ruby 4.0対応版の parser / better_html / erb_lint が出たら更新予定
  # parser/current の互換性warningを解消する。
  gem "erb_lint", require: false

  # i18n unused/missing key checker
  gem "i18n-tasks", require: false
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  gem "webmock"
end

# 認証基盤 [https://github.com/heartcombo/devise]
gem "devise", "~> 5.0"
# Devise日本語化 [https://github.com/devise-i18n/devise-i18n]
gem "devise-i18n"
