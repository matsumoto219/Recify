# frozen_string_literal: true

require Rails.root.join("app/services/production_env_validator")

ProductionEnvValidator.boot_validate! unless ARGV.include?("recify:env:validate")
