# frozen_string_literal: true

namespace :recify do
  namespace :env do
    desc "Validate required production environment configuration"
    task validate: :environment do
      ProductionEnvValidator.validate!(strict: true)
      ProductionDataPlaneValidator.validate!
      puts "Production environment and data-plane configuration is valid."
    rescue ProductionEnvValidator::ValidationError, ProductionDataPlaneValidator::ValidationError => e
      warn e.message
      raise
    end
  end

  namespace :production do
    desc "Validate production DB, Solid Queue/Cable/Cache, storage, and recurring cleanup configuration"
    task validate_data_plane: :environment do
      ProductionDataPlaneValidator.validate!
      puts "Production data-plane configuration is valid."
    rescue ProductionDataPlaneValidator::ValidationError => e
      warn e.message
      raise
    end
  end
end
