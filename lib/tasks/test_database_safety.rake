# frozen_string_literal: true

require_relative "../recify/test_database_guard"

namespace :recify do
  task :test_database_safety do
    Recify::TestDatabaseGuard.assert_test_environment!(environment: Rails.env.to_s)
    Rake::Task["db:load_config"].invoke
    Recify::TestDatabaseGuard.validate!(
      environment: Rails.env.to_s,
      configurations: ActiveRecord::Base.configurations.configs_for(env_name: "test", include_hidden: true)
    )
  end
end

Rake::Task.tasks.each do |task|
  next unless task.name.match?(/\Adb:test:(?:prepare|load_schema|purge)(?::[^:]+)?\z/)

  # A normal enhancement appends prerequisites after the schema purge dependency.
  task.prerequisites.unshift("recify:test_database_safety")
end
