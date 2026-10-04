# frozen_string_literal: true

module Recify
  module TestDatabaseGuard
    class Error < StandardError; end

    ERROR_MESSAGE = "Tests require an approved local PostgreSQL test database."
    DATABASE_NAME = /\Arecify_(?:test|bot_cable_test)(?:_\d{1,4})?\z/
    LOCAL_HOSTS = [ nil, "", "localhost", "127.0.0.1", "::1", "/tmp", "/var/run/postgresql", "/run/postgresql" ].freeze
    LOCAL_ADDRESSES = [ nil, "", "127.0.0.1", "::1" ].freeze
    FORBIDDEN_ENV_KEYS = %w[DISABLE_DATABASE_ENVIRONMENT_CHECK PGSERVICE PGSERVICEFILE PGOPTIONS].freeze
    FORBIDDEN_CONFIG_KEYS = %i[service servicefile options].freeze

    module_function

    def assert_test_environment!(environment:, env: ENV)
      raise Error, ERROR_MESSAGE unless environment == "test"
      raise Error, ERROR_MESSAGE if FORBIDDEN_ENV_KEYS.any? { |key| env.key?(key) }

      true
    end

    def validate!(environment:, configurations:, env: ENV)
      assert_test_environment!(environment: environment, env: env)
      raise Error, ERROR_MESSAGE unless configurations.is_a?(Array) && configurations.any?
      raise Error, ERROR_MESSAGE unless configurations.all? { |configuration| safe_configuration?(configuration, env) }

      true
    end

    def safe_configuration?(configuration, env)
      return false unless configuration.env_name == "test"

      config = configuration.configuration_hash
      return false unless config.is_a?(Hash) && config[:adapter] == "postgresql"
      return false if FORBIDDEN_CONFIG_KEYS.any? { |key| config.key?(key) }
      return false unless safe_database_name?(config[:database])
      return false unless LOCAL_HOSTS.include?(effective_connection_value(config[:host], env["PGHOST"]))
      return false unless LOCAL_ADDRESSES.include?(effective_connection_value(config[:hostaddr], env["PGHOSTADDR"]))
      return false unless [ nil, "public" ].include?(config[:schema_search_path])

      variables = config[:variables]
      variables.nil? || (variables.is_a?(Hash) && [ nil, "public" ].include?(variables[:search_path] || variables["search_path"]))
    end
    private_class_method :safe_configuration?

    def safe_database_name?(database)
      database.is_a?(String) && database.ascii_only? && database.bytesize <= 63 && DATABASE_NAME.match?(database)
    end
    private_class_method :safe_database_name?

    def effective_connection_value(configured, fallback)
      configured.nil? || configured == "" ? fallback : configured
    end
    private_class_method :effective_connection_value
  end
end
