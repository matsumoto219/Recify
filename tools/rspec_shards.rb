# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"

module RSpecShards
  class Error < StandardError; end

  class Planner
    attr_reader :groups

    def initialize(files:, durations:, count:)
      raise Error, "Shard count must be a positive integer" unless count.is_a?(Integer) && count.positive?
      raise Error, "Each shard must contain at least one spec file" if files.size < count
      raise Error, "Spec files must be unique" unless files.uniq == files
      unless durations.is_a?(Hash) && durations.values.all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? }
        raise Error, "Recorded durations must be finite positive numbers"
      end

      recorded = durations.values.sort
      fallback = recorded.empty? ? 1.0 : recorded.fetch(recorded.size / 2)
      @groups = Array.new(count) { [] }
      totals = Array.new(count, 0.0)

      files.sort_by { |path| [ -durations.fetch(path, fallback), path ] }.each do |path|
        index = (0...count).min_by { |candidate| [ totals.fetch(candidate), candidate ] }
        @groups.fetch(index) << path
        totals[index] += durations.fetch(path, fallback)
      end
      @groups.each(&:sort!)
    end

    def files_for(index)
      unless index.is_a?(Integer) && index.between?(1, groups.size)
        raise Error, "Shard index must be between 1 and the shard count"
      end

      groups.fetch(index - 1)
    end
  end

  class Cli
    def initialize(arguments, root:, out: $stdout, err: $stderr)
      @arguments = arguments
      @root = root
      @out = out
      @err = err
    end

    def call
      options = { index: nil, total: nil, seed: nil, list: false }
      parser = OptionParser.new do |flags|
        flags.banner = "Usage: bin/rspec_shard --index N --total N [--seed N] [--list]"
        flags.on("--index N", Integer) { |value| options[:index] = value }
        flags.on("--total N", Integer) { |value| options[:total] = value }
        flags.on("--seed N", Integer) { |value| options[:seed] = value }
        flags.on("--list") { options[:list] = true }
      end
      remaining = parser.parse(@arguments)
      raise Error, "Unexpected arguments; each shard always runs all assigned examples" unless remaining.empty?
      raise Error, "RSpec shards only support RAILS_ENV=test" unless ENV.fetch("RAILS_ENV", "test") == "test"
      raise Error, "Seed must be nonnegative" if options[:seed] && options[:seed].negative?

      durations = JSON.parse(File.read(File.join(@root, "spec/rspec_file_durations.json")))
      planner = Planner.new(
        files: Dir.glob("spec/**/*_spec.rb", base: @root),
        durations: durations,
        count: options[:total]
      )
      files = planner.files_for(options[:index])
      if options[:list]
        @out.puts(files)
        return 0
      end

      run(files, options)
    rescue Error, OptionParser::ParseError, JSON::ParserError, SystemCallError, KeyError, TypeError
      @err.puts("RSpec shard failed: check shard arguments, duration data, and RSpec result completeness.")
      1
    end

    private

    def run(files, options)
      output_dir = File.join(@root, "tmp/rspec")
      FileUtils.mkdir_p(output_dir)
      raw_path = File.join(output_dir, "shard-#{options.fetch(:index)}-raw.json")
      summary_path = File.join(output_dir, "shard-#{options.fetch(:index)}.json")
      FileUtils.rm_f([ raw_path, summary_path ])
      command = [
        "bundle", "exec", "rspec", "--options", File::NULL, "--require", "spec_helper", *files,
        "--format", "progress", "--format", "json", "--out", raw_path
      ]
      command.concat([ "--seed", options[:seed].to_s ]) if options[:seed]

      @out.puts("RSpec shard #{options.fetch(:index)}/#{options.fetch(:total)}: #{files.size} files")
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cpu_before = Process.times
      status = run_rspec(command)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      cpu_after = Process.times
      result = JSON.parse(File.read(raw_path))
      summary = result.fetch("summary")
      examples = result.fetch("examples")
      files_run = examples.map { |example| example.fetch("file_path").delete_prefix("./") }.uniq.sort
      unless summary.fetch("example_count").positive? && examples.size == summary.fetch("example_count") && files_run == files
        raise Error, "RSpec did not execute every assigned spec file"
      end

      metrics = {
        shard: options.fetch(:index),
        shard_count: options.fetch(:total),
        seed: result.fetch("seed"),
        file_count: files.size,
        example_count: summary.fetch("example_count"),
        failure_count: summary.fetch("failure_count"),
        pending_count: summary.fetch("pending_count"),
        errors_outside_of_examples_count: summary.fetch("errors_outside_of_examples_count"),
        duration: summary.fetch("duration"),
        wall_time: elapsed.round(3),
        user_time: (cpu_after.cutime - cpu_before.cutime).round(3),
        system_time: (cpu_after.cstime - cpu_before.cstime).round(3),
        files: examples.group_by { |example| example.fetch("file_path").delete_prefix("./") }.sort.to_h.transform_values do |entries|
          { example_count: entries.size, duration: entries.sum { |entry| entry.fetch("run_time") }.round(6) }
        end
      }
      File.write(summary_path, JSON.pretty_generate(metrics) + "\n")
      @out.puts("RSPEC_SHARD_METRICS=#{JSON.generate(metrics)}")
      return status unless status.zero?

      summary.fetch("failure_count").zero? && summary.fetch("errors_outside_of_examples_count").zero? ? 0 : 1
    ensure
      FileUtils.rm_f(raw_path) if raw_path
    end

    def run_rspec(command)
      pid = Process.spawn(
        { "RAILS_ENV" => "test", "SPEC_OPTS" => nil, "RSPEC_OPTS" => nil },
        *command,
        chdir: @root
      )
      _pid, status = Process.wait2(pid)
      status.exitstatus || 1
    end
  end
end
