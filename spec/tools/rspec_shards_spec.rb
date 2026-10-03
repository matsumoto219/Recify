# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../tools/rspec_shards"

RSpec.describe RSpecShards::Planner do
  let(:files) { %w[spec/system/large_spec.rb spec/services/large_spec.rb spec/medium_spec.rb spec/small_spec.rb] }
  let(:durations) { files.zip([ 9.0, 8.0, 2.0, 1.0 ]).to_h }

  it "assigns all files, including system specs, exactly once and balances recorded work" do
    planner = described_class.new(files: files, durations: durations, count: 2)

    aggregate_failures do
      expect(planner.groups.flatten.sort).to eq(files.sort)
      expect(planner.groups.map { |group| group.sum { |path| durations.fetch(path) } }).to eq([ 10.0, 10.0 ])
      expect(planner.files_for(1)).to include("spec/system/large_spec.rb")
    end
  end

  it "uses a stable assignment regardless of input ordering or equal durations" do
    durations = files.to_h { |path| [ path, 1.0 ] }
    forward = described_class.new(files: files, durations: durations, count: 2)
    reverse = described_class.new(files: files.reverse, durations: durations, count: 2)

    expect(reverse.groups).to eq(forward.groups)
  end

  it "includes new specs and never runs deleted paths left in the duration data" do
    current_files = files + [ "spec/new_spec.rb" ]
    recorded = durations.merge("spec/deleted_spec.rb" => 100.0)
    planner = described_class.new(files: current_files, durations: recorded, count: 2)

    expect(planner.groups.flatten.sort).to eq(current_files.sort)
  end

  it "can partition an entirely unmeasured suite without leaving a worker empty" do
    planner = described_class.new(files: files, durations: {}, count: 4)

    expect(planner.groups.map(&:size)).to eq([ 1, 1, 1, 1 ])
  end

  it "rejects invalid counts, duplicate paths, and empty workers" do
    [ 0, -1, nil, 1.5, 5 ].each do |count|
      expect { described_class.new(files: files, durations: durations, count: count) }.to raise_error(RSpecShards::Error)
    end
    expect { described_class.new(files: [], durations: {}, count: 1) }.to raise_error(RSpecShards::Error)
    expect { described_class.new(files: files + files, durations: durations, count: 2) }.to raise_error(RSpecShards::Error)
  end

  it "rejects unusable duration data and out-of-range shard indexes" do
    [ nil, [], { files.first => -1 }, { files.first => "1" }, { files.first => Float::INFINITY } ].each do |recorded|
      expect { described_class.new(files: files, durations: recorded, count: 2) }.to raise_error(RSpecShards::Error)
    end
    planner = described_class.new(files: files, durations: durations, count: 2)
    [ 0, -1, 3, nil ].each do |index|
      expect { planner.files_for(index) }.to raise_error(RSpecShards::Error)
    end
  end
end

RSpec.describe RSpecShards::Cli do
  around do |example|
    Dir.mktmpdir("rspec-shards") do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, "spec/system"))
      File.write(File.join(root, "spec/system/example_spec.rb"), "")
      File.write(File.join(root, "spec/rspec_file_durations.json"), "{}")
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:errors) { StringIO.new }
  let(:arguments) { %w[--index 1 --total 1 --seed 12345] }
  let(:cli) { described_class.new(arguments, root: @root, out: output, err: errors) }
  let(:result) do
    {
      "seed" => 12345,
      "summary" => {
        "example_count" => 1,
        "failure_count" => 0,
        "pending_count" => 0,
        "errors_outside_of_examples_count" => 0,
        "duration" => 0.5
      },
      "examples" => [
        {
          "file_path" => "./spec/system/example_spec.rb",
          "run_time" => 0.5,
          "full_description" => "private fixture details",
          "exception" => { "message" => "private response" }
        }
      ]
    }
  end

  def stub_rspec(exit_status: 0, report: result)
    allow(Process).to receive(:spawn) do |environment, *command, **options|
      @child_environment = environment
      @child_command = command
      @child_options = options
      report_path = command.fetch(command.index("--out") + 1)
      File.write(report_path, JSON.generate(report)) if report
      12_345
    end
    allow(Process).to receive(:wait2).with(12_345).and_return(
      [ 12_345, instance_double(Process::Status, exitstatus: exit_status) ]
    )
  end

  it "runs explicit file arguments without inherited filters and publishes only safe metrics" do
    stub_rspec

    aggregate_failures do
      expect(cli.call).to eq(0)
      expect(@child_environment).to eq("RAILS_ENV" => "test", "SPEC_OPTS" => nil, "RSPEC_OPTS" => nil)
      expect(@child_command).to include("spec/system/example_spec.rb", "--seed", "12345")
      expect(@child_command.take(7)).to eq([ "bundle", "exec", "rspec", "--options", File::NULL, "--require", "spec_helper" ])
      expect(@child_options).to eq(chdir: @root)
      expect(output.string).to include('"example_count":1', '"seed":12345', '"wall_time":', '"user_time":')
      expect(output.string).not_to include("private fixture details", "private response", "full_description", "exception")
      expect(File).not_to exist(File.join(@root, "tmp/rspec/shard-1-raw.json"))
      expect(JSON.parse(File.read(File.join(@root, "tmp/rspec/shard-1.json")))).to include("file_count" => 1)
    end
  end

  it "passes spaces and shell metacharacters in file names as one argument" do
    path = "spec/special ; name_spec.rb"
    File.write(File.join(@root, path), "")
    result.fetch("examples") << { "file_path" => "./#{path}", "run_time" => 0.2 }
    result.fetch("summary")["example_count"] = 2
    stub_rspec

    aggregate_failures do
      expect(cli.call).to eq(0)
      expect(@child_command).to include(path)
    end
  end

  it "propagates a failing RSpec process even when its summary reports no failed examples" do
    stub_rspec(exit_status: 3)

    expect(cli.call).to eq(3)
  end

  it "fails for a reported failure even if the child returned success" do
    result.fetch("summary")["failure_count"] = 1
    stub_rspec

    expect(cli.call).to eq(1)
  end

  it "fails instead of accepting an empty or filtered result" do
    result.fetch("summary")["example_count"] = 0
    result["examples"] = []
    stub_rspec

    expect(cli.call).to eq(1)
  end

  it "fails if any assigned file is absent from the results" do
    File.write(File.join(@root, "spec/missing_spec.rb"), "")
    stub_rspec

    expect(cli.call).to eq(1)
  end

  it "does not reuse an old report when the child produces no results" do
    FileUtils.mkdir_p(File.join(@root, "tmp/rspec"))
    File.write(File.join(@root, "tmp/rspec/shard-1-raw.json"), JSON.generate(result))
    File.write(File.join(@root, "tmp/rspec/shard-1.json"), JSON.generate(result))
    stub_rspec(report: nil)

    aggregate_failures do
      expect(cli.call).to eq(1)
      expect(File).not_to exist(File.join(@root, "tmp/rspec/shard-1.json"))
    end
  end

  it "rejects additional RSpec filters before starting a child process" do
    filtered = described_class.new(arguments + [ "--example", "one case" ], root: @root, out: output, err: errors)

    expect(Process).not_to receive(:spawn)
    expect(filtered.call).to eq(1)
  end

  it "can list its complete assignment without starting RSpec" do
    listed = described_class.new(arguments + [ "--list" ], root: @root, out: output, err: errors)

    expect(Process).not_to receive(:spawn)
    aggregate_failures do
      expect(listed.call).to eq(0)
      expect(output.string).to eq("spec/system/example_spec.rb\n")
    end
  end
end
