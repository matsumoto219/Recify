# frozen_string_literal: true

require "open3"
require "yaml"

RSpec.describe "GitHub CI test gate" do
  let(:workflow) { YAML.safe_load_file(File.expand_path("../../.github/workflows/ci.yml", __dir__)) }
  let(:jobs) { workflow.fetch("jobs") }
  let(:gate) { jobs.fetch("test") }
  let(:verification) { gate.fetch("steps").find { |step| step.fetch("name") == "Verify complete test results" } }

  def gate_succeeds?(classification: "success", docs_only: "false", rspec: "success")
    _stdout, _stderr, status = Open3.capture3(
      { "CLASSIFICATION_RESULT" => classification, "DOCS_ONLY" => docs_only, "RSPEC_RESULT" => rspec },
      "bash", "-c", verification.fetch("run")
    )
    status.success?
  end

  it "retains the required test check and waits for classification and every matrix worker" do
    matrix_job = jobs.fetch("rspec")
    strategy = matrix_job.fetch("strategy")

    aggregate_failures do
      expect(gate.fetch("if")).to eq("always()")
      expect(gate.fetch("needs")).to contain_exactly("classify_changes", "rspec")
      expect(strategy.fetch("fail-fast")).to be(false)
      expect(strategy.fetch("matrix").fetch("shard")).to eq((1..matrix_job.fetch("env").fetch("RSPEC_SHARD_COUNT")).to_a)
      expect(matrix_job.fetch("continue-on-error", false)).to be(false)
      expect(matrix_job.fetch("services").fetch("postgres").fetch("ports")).to include("5432:5432")
    end
  end

  it "runs all assigned RSpec files and preserves the Minitest and preparation gates" do
    steps = jobs.fetch("rspec").fetch("steps")
    minitest = steps.find { |step| step["name"] == "Run Minitest" }
    commands = steps.filter_map { |step| step["run"] }

    aggregate_failures do
      expect(commands).to include(
        "bin/check_duplicate_files",
        "bin/rails db:test:prepare",
        "bundle exec rails zeitwerk:check",
        "ruby bin/generated_receipts_validate",
        'bundle exec ruby bin/rspec_shard --index "$RSPEC_SHARD" --total "$RSPEC_SHARD_COUNT" --seed "$RSPEC_SEED"'
      )
      expect(commands).to include(a_string_including("bin/rails tailwindcss:build"))
      expect(minitest).to include("if" => "matrix.shard == 1", "run" => "bin/rails test")
    end
  end

  it "accepts full verification only when the matrix is successful" do
    expect(gate_succeeds?).to be(true)
    %w[failure cancelled skipped unknown].each do |result|
      expect(gate_succeeds?(rspec: result)).to be(false), "Unexpected success for RSpec result #{result}"
    end
  end

  it "accepts the existing documentation-only exemption only with successful classification" do
    aggregate_failures do
      expect(gate_succeeds?(docs_only: "true", rspec: "skipped")).to be(true)
      expect(gate_succeeds?(docs_only: "true", rspec: "failure")).to be(false)
      expect(gate_succeeds?(classification: "failure", docs_only: "true", rspec: "skipped")).to be(false)
    end
  end

  it "fails closed for a failed, cancelled, skipped, or missing classification" do
    [ "failure", "cancelled", "skipped", "" ].each do |result|
      expect(gate_succeeds?(classification: result)).to be(false), "Unexpected success for classification #{result}"
    end
    [ "", "unknown" ].each do |docs_only|
      expect(gate_succeeds?(docs_only: docs_only)).to be(false), "Unexpected success for docs_only #{docs_only}"
    end
  end
end
