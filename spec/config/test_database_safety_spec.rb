# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require_relative "../../lib/recify/test_database_guard"

RSpec.describe Recify::TestDatabaseGuard do
  let(:configuration_class) { Struct.new(:env_name, :configuration_hash) }
  let(:configuration) { { adapter: "postgresql", database: "recify_test" } }
  let(:environment) { {} }

  def validate(configuration = self.configuration, env: environment, rails_environment: "test")
    described_class.validate!(
      environment: rails_environment,
      configurations: [ configuration_class.new("test", configuration) ],
      env: env
    )
  end

  describe ".validate!" do
    %w[recify_test recify_bot_cable_test recify_test_0 recify_test_31].each do |database|
      it "accepts the approved local test database #{database}" do
        expect(validate(configuration.merge(database: database))).to be(true)
      end
    end

    [ nil, "", "localhost", "127.0.0.1", "::1", "/tmp", "/var/run/postgresql", "/run/postgresql" ].each do |host|
      it "accepts the local host #{host.inspect}" do
        expect(validate(configuration.merge(host: host))).to be(true)
      end
    end

    it "accepts the CI PostgreSQL environment without depending on credentials" do
      expect(validate(env: { "PGHOST" => "localhost", "PGUSER" => "postgres", "PGPASSWORD" => "synthetic" })).to be(true)
    end

    it "uses explicit host and hostaddr instead of unused environment fallbacks" do
      expect(validate(configuration.merge(host: "localhost", hostaddr: "127.0.0.1"), env: {
        "PGHOST" => "remote.invalid", "PGHOSTADDR" => "192.0.2.1"
      })).to be(true)
    end

    %w[development production].each do |rails_environment|
      it "rejects #{rails_environment} even with an approved database name" do
        expect { validate(rails_environment: rails_environment) }.to raise_error(described_class::Error)
      end
    end

    [ nil, "recify_development", "recify_production", "other_test", "recify_test_extra", "recify_test_0 production" ].each do |database|
      it "rejects the unapproved database #{database.inspect}" do
        expect { validate(configuration.merge(database: database)) }.to raise_error(described_class::Error)
      end
    end

    it "rejects a non-PostgreSQL adapter" do
      expect { validate(configuration.merge(adapter: "sqlite3")) }.to raise_error(described_class::Error)
    end

    it "rejects an empty resolved configuration set" do
      expect do
        described_class.validate!(environment: "test", configurations: [], env: {})
      end.to raise_error(described_class::Error)
    end

    it "checks every resolved configuration, including hidden configurations" do
      configurations = [
        configuration_class.new("test", configuration),
        configuration_class.new("test", configuration.merge(database: "recify_production"))
      ]

      expect do
        described_class.validate!(environment: "test", configurations: configurations, env: {})
      end.to raise_error(described_class::Error)
    end

    it "rejects a configuration from another environment" do
      expect do
        described_class.validate!(environment: "test", configurations: [ configuration_class.new("production", configuration) ], env: {})
      end.to raise_error(described_class::Error)
    end

    [ "remote.invalid", "192.0.2.1", "localhost,remote.invalid", "/unapproved/socket", false ].each do |host|
      it "rejects the non-local or malformed host #{host.inspect}" do
        expect { validate(configuration.merge(host: host)) }.to raise_error(described_class::Error)
      end
    end

    [ nil, "" ].each do |host|
      it "rejects a remote PGHOST fallback when the configured host is #{host.inspect}" do
        expect { validate(configuration.merge(host: host), env: { "PGHOST" => "remote.invalid" }) }.to raise_error(described_class::Error)
      end
    end

    it "rejects a remote PGHOSTADDR even when the host name is localhost" do
      expect do
        validate(configuration.merge(host: "localhost"), env: { "PGHOSTADDR" => "192.0.2.1" })
      end.to raise_error(described_class::Error)
    end

    it "rejects a configured remote hostaddr" do
      expect { validate(configuration.merge(hostaddr: "192.0.2.1")) }.to raise_error(described_class::Error)
    end

    %w[PGSERVICE PGSERVICEFILE PGOPTIONS].each do |key|
      it "rejects #{key} indirection before it reaches libpq" do
        expect { validate(env: { key => "synthetic" }) }.to raise_error(described_class::Error)
      end
    end

    %i[service servicefile options].each do |key|
      it "rejects configured #{key} indirection" do
        expect { validate(configuration.merge(key => "synthetic")) }.to raise_error(described_class::Error)
      end
    end

    [ "", "0", "false", "1" ].each do |value|
      it "rejects the environment-check bypass flag even when set to #{value.inspect}" do
        expect do
          validate(env: { "DISABLE_DATABASE_ENVIRONMENT_CHECK" => value })
        end.to raise_error(described_class::Error)
      end
    end

    [ nil, "public" ].each do |search_path|
      it "accepts the standard schema search path #{search_path.inspect}" do
        expect(validate(configuration.merge(schema_search_path: search_path))).to be(true)
      end
    end

    [ "private", "public, private", "", [ "public" ] ].each do |search_path|
      it "rejects custom or malformed schema search path #{search_path.inspect}" do
        expect { validate(configuration.merge(schema_search_path: search_path)) }.to raise_error(described_class::Error)
      end
    end

    it "rejects a variables search_path override" do
      expect do
        validate(configuration.merge(variables: { search_path: "private" }))
      end.to raise_error(described_class::Error)
    end

    it "rejects a malformed database name without exposing connection data" do
      error = nil
      begin
        validate(configuration.merge(database: "invalid\xFF".b, password: "synthetic-secret", host: "private.invalid"))
      rescue described_class::Error => exception
        error = exception
      end

      expect(error).to be_a(described_class::Error)
      expect(error.message.bytesize).to be <= 128
      expect(error.message).not_to match(/synthetic-secret|private\.invalid|invalid/)
    end

    it "does not mutate the configuration or environment" do
      expect(validate(configuration.freeze, env: { "PGHOST" => "localhost" }.freeze)).to be(true)
    end
  end

  describe "test task integration" do
    let(:root) { File.expand_path("../..", __dir__) }

    def invoke_fake_task(task_name, database: "recify_test", rails_environment: "test")
      harness = <<~RUBY
        require "json"
        require "rake"

        Rails = Struct.new(:env).new(ARGV.fetch(2))
        config = Struct.new(:env_name, :configuration_hash).new("test", { adapter: "postgresql", database: ARGV.fetch(1) })
        configurations = Object.new
        configurations.define_singleton_method(:configs_for) do |env_name:, include_hidden:|
          raise "hidden configuration check missing" unless env_name == "test" && include_hidden
          [config]
        end
        ActiveRecord = Module.new
        ActiveRecord.const_set(:Base, Struct.new(:configurations).new(configurations))
        events = []
        Rake::Task.define_task("db:load_config") { events << "load_config" }
        Rake::Task.define_task("db:check_protected_environments" => ["db:load_config"]) { events << "protected" }
        ["", ":primary"].each do |suffix|
          Rake::Task.define_task("db:test:purge\#{suffix}" => ["db:load_config", "db:check_protected_environments"]) { events << "purge" }
          Rake::Task.define_task("db:test:load_schema\#{suffix}" => ["db:test:purge\#{suffix}"]) { events << "load_schema" }
          Rake::Task.define_task("db:test:prepare\#{suffix}" => ["db:load_config"]) do
            Rake::Task["db:test:load_schema\#{suffix}"].invoke
          end
        end
        load ARGV.fetch(3)
        begin
          Rake::Task[ARGV.fetch(0)].invoke
        rescue Recify::TestDatabaseGuard::Error
          events << "blocked"
        end
        puts JSON.generate(events)
      RUBY
      clean_environment = %w[PGHOST PGHOSTADDR PGSERVICE PGSERVICEFILE PGOPTIONS DISABLE_DATABASE_ENVIRONMENT_CHECK].to_h { |key| [ key, nil ] }
      stdout, stderr, status = Open3.capture3(
        clean_environment, RbConfig.ruby, "-e", harness,
        task_name, database, rails_environment, File.join(root, "lib/tasks/test_database_safety.rake"), chdir: root
      )
      expect(status).to be_success, stderr
      JSON.parse(stdout)
    end

    %w[db:test:prepare db:test:load_schema db:test:purge db:test:prepare:primary db:test:load_schema:primary db:test:purge:primary].each do |task_name|
      it "blocks #{task_name} before any destructive task action" do
        expect(invoke_fake_task(task_name, database: "recify_production")).to eq([ "load_config", "blocked" ])
      end
    end

    it "preserves Rails protected-environment checks and the ordinary task order" do
      expect(invoke_fake_task("db:test:prepare")).to eq([ "load_config", "protected", "purge", "load_schema" ])
    end

    it "rejects a non-test environment before loading application configuration" do
      expect(invoke_fake_task("db:test:prepare", rails_environment: "production")).to eq([ "blocked" ])
    end

    %w[spec/rails_helper.rb test/test_helper.rb].each do |helper|
      it "guards #{helper} before application boot and schema maintenance" do
        source = File.read(File.join(root, helper))
        expect(source.index("assert_test_environment!")).to be < source.index("config/environment")
        expect(source.index("validate!")).to be < source.index(helper.start_with?("spec/") ? "maintain_test_schema!" : "rails/test_help")
        expect(source).to include('configs_for(env_name: "test", include_hidden: true)')
      end
    end
  end
end
