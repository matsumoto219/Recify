# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Local CI entry point" do
  let(:root) { File.expand_path("../..", __dir__) }

  def run_ci(environment: nil, failed_command: nil)
    harness = <<~RUBY
      require "json"
      require "active_support/continuous_integration"

      ActiveSupport::ContinuousIntegration.class_eval do
        def system(*command)
          puts "CI_COMMAND=\#{JSON.generate(command: command, environment: ENV["RAILS_ENV"])}"
          command.join(" ") != ENV["FAILED_CI_COMMAND"]
        end
      end

      load ARGV.fetch(0)
    RUBY

    stdout, stderr, status = Open3.capture3(
      { "RAILS_ENV" => environment, "FAILED_CI_COMMAND" => failed_command },
      RbConfig.ruby, "-e", harness, File.join(root, "bin/ci"), chdir: root
    )
    commands = stdout.lines.filter_map do |line|
      JSON.parse(line.delete_prefix("CI_COMMAND=")) if line.start_with?("CI_COMMAND=")
    end

    [ commands, stderr, status ]
  end

  it "runs every test runner and its prerequisites only in the test environment" do
    commands, _stderr, status = run_ci
    command_lines = commands.map { |entry| entry.fetch("command").join(" ") }

    aggregate_failures do
      expect(status).to be_success
      expect(commands).not_to be_empty
      expect(commands.map { |entry| entry.fetch("environment") }.uniq).to eq([ "test" ])
      expect(command_lines).to include(
        "bin/check_duplicate_files",
        "bash -o pipefail -c git ls-files -z | xargs -0 bin/rubocop --force-exclusion --only-recognized-file-types",
        "bin/rails db:test:prepare",
        "bin/rails tailwindcss:build",
        "bundle exec rails zeitwerk:check",
        "ruby bin/generated_receipts_validate",
        "env -u SPEC_OPTS -u RSPEC_OPTS bundle exec rspec --options /dev/null --require spec_helper",
        "bin/rails test",
        "npm run test:stylelint"
      )
      expect(command_lines).not_to include(a_string_matching(/bin\/setup|db:reset|db:seed:replant|log:clear|tmp:clear/))
    end
  end

  it "rejects a non-test environment before any command is started" do
    %w[development production].each do |environment|
      commands, stderr, status = run_ci(environment: environment)

      aggregate_failures(environment) do
        expect(status).not_to be_success
        expect(commands).to be_empty
        expect(stderr).to include("bin/ci only supports RAILS_ENV=test")
      end
    end
  end

  it "fails the entry point when RSpec fails" do
    _commands, _stderr, status = run_ci(
      environment: "test",
      failed_command: "env -u SPEC_OPTS -u RSPEC_OPTS bundle exec rspec --options /dev/null --require spec_helper"
    )

    expect(status).not_to be_success
  end

  it "fails the entry point when a non-RSpec test runner fails" do
    _commands, _stderr, status = run_ci(environment: "test", failed_command: "npm run test:stylelint")

    expect(status).not_to be_success
  end

  it "checks JavaScript files after the first controller and propagates syntax errors" do
    commands, _stderr, _status = run_ci
    syntax_command = commands.find { |entry| entry.fetch("command").join(" ").include?("node --check") }.fetch("command")

    Dir.mktmpdir("ci-javascript") do |directory|
      controllers = File.join(directory, "app/javascript/controllers")
      FileUtils.mkdir_p(controllers)
      File.write(File.join(controllers, "first.js"), "const first = true\n")
      File.write(File.join(controllers, "second.js"), "const second = true\n")
      _stdout, _stderr, status = Open3.capture3(*syntax_command, chdir: directory)
      expect(status).to be_success

      File.write(File.join(controllers, "second.js"), "const second =\n")
      _stdout, _stderr, status = Open3.capture3(*syntax_command, chdir: directory)
      expect(status).not_to be_success
    end
  end
end
