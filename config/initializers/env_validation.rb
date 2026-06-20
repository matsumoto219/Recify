# frozen_string_literal: true

require Rails.root.join("app/services/production_env_validator")

skip_boot_env_validation = ARGV.any? do |argument|
  argument.in?(%w[recify:env:validate recify:production:validate_data_plane])
end

ProductionEnvValidator.boot_validate! unless skip_boot_env_validation
