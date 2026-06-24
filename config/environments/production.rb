require "active_support/core_ext/integer/time"
require Rails.root.join("app/services/production_runtime_config")
require Rails.root.join("config/cloudflare_trusted_proxies")

Rails.application.configure do
  runtime_config = ProductionRuntimeConfig.new

  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume SSL-terminating reverse proxy access by default. Override only for controlled smoke checks.
  config.assume_ssl = runtime_config.assume_ssl?

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = runtime_config.force_ssl?

  # Skip http-to-https redirect for the default health check endpoint.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } } if config.force_ssl

  # Cloudflare proxy traffic reaches Rails through Cloudflare edge IPs and the
  # Kamal/Docker network. Keep Rails' default private proxy ranges and add the
  # official Cloudflare ranges so request.remote_ip resolves to the visitor.
  config.action_dispatch.trusted_proxies = Recify::CloudflareTrustedProxies.action_dispatch_trusted_proxies

  # Rack::Attack keys use request.ip, which is calculated by Rack rather than
  # ActionDispatch::RemoteIp. Keep Rack's default private proxy filter and add
  # the same Cloudflare ranges so Rack::Attack does not group users by edge IP.
  Rack::Request.ip_filter = Recify::CloudflareTrustedProxies.rack_ip_filter

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Raise delivery errors in production so SMTP configuration issues are visible during smoke checks.
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.perform_deliveries = true
  config.action_mailer.delivery_method = :smtp

  # Set host to be used by links generated in mailer templates.
  routes.default_url_options = runtime_config.routes_default_url_options
  config.action_mailer.default_url_options = runtime_config.mailer_default_url_options

  smtp_settings = runtime_config.smtp_settings
  config.action_mailer.smtp_settings = smtp_settings if smtp_settings.present?

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks without allowing every host.
  config.hosts.concat(runtime_config.host_authorization_hosts)

  # Skip DNS rebinding protection for the default health check endpoint.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
