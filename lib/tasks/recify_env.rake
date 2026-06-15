# frozen_string_literal: true

namespace :recify do
  namespace :env do
    desc "Validate required production environment configuration"
    task validate: :environment do
      ProductionEnvValidator.validate!(strict: true)
      puts "Production environment configuration is valid."
    rescue ProductionEnvValidator::ValidationError => e
      warn e.message
      raise
    end
  end
end
