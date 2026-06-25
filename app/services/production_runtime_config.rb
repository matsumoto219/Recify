# frozen_string_literal: true

class ProductionRuntimeConfig
  DEFAULT_PROTOCOL = "https"
  SMTP_REQUIRED_ENV = %w[
    SMTP_HOST
    SMTP_PORT
    SMTP_USERNAME
    SMTP_PASSWORD
    SMTP_FROM
  ].freeze

  def initialize(env: ENV)
    @env = env
  end

  def app_host
    env_value("APP_HOST") || env_value("DEFAULT_URL_HOST")
  end

  def app_protocol
    normalize_protocol(env_value("APP_PROTOCOL") || DEFAULT_PROTOCOL)
  end

  def mailer_host
    env_value("MAILER_HOST") || app_host
  end

  def mailer_protocol
    normalize_protocol(env_value("MAILER_PROTOCOL") || app_protocol)
  end

  def host_authorization_hosts
    ([ app_host, mailer_host ] + additional_hosts).compact_blank.uniq
  end

  def additional_hosts
    env.fetch("APP_ADDITIONAL_HOSTS", "").split(",").map { |host| normalize_host(host) }.compact_blank
  end

  def force_ssl?
    boolean_env("FORCE_SSL", default: true)
  end

  def assume_ssl?
    boolean_env("ASSUME_SSL", default: true)
  end

  def ssl_options
    {
      hsts: { expires: 0, subdomains: false, preload: false },
      redirect: { exclude: ->(request) { request.path == "/up" } }
    }
  end

  def routes_default_url_options
    url_options_for(app_host, app_protocol)
  end

  def mailer_default_url_options
    url_options_for(mailer_host, mailer_protocol)
  end

  def smtp_settings
    return {} unless smtp_env_present?

    {
      address: env_value("SMTP_HOST"),
      port: smtp_port,
      user_name: env_value("SMTP_USERNAME"),
      password: env_value("SMTP_PASSWORD"),
      authentication: :plain,
      enable_starttls_auto: true
    }.compact
  end

  def smtp_env_present?
    SMTP_REQUIRED_ENV.any? { |key| env_value(key).present? }
  end

  def missing_smtp_env
    SMTP_REQUIRED_ENV.reject { |key| env_value(key).present? }
  end

  private

  attr_reader :env

  def url_options_for(host, protocol)
    { host: host, protocol: protocol }.compact_blank
  end

  def smtp_port
    value = env_value("SMTP_PORT")
    return if value.blank?

    Integer(value)
  rescue ArgumentError
    value
  end

  def env_value(key)
    env[key].to_s.strip.presence
  end

  def normalize_host(value)
    value.to_s.strip.presence
  end

  def normalize_protocol(value)
    value.to_s.strip.delete_suffix("://").presence || DEFAULT_PROTOCOL
  end

  def boolean_env(key, default:)
    raw = env[key]
    return default if raw.nil?

    ActiveModel::Type::Boolean.new.cast(raw)
  end
end
