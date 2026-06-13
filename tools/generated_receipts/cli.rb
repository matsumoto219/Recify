# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../generated_receipts"

module GeneratedReceipts
  class Cli
    def self.call(argv)
      new(argv).call
    end

    def initialize(argv)
      @argv = argv
    end

    def call
      write_text = argv.include?("--write-text")
      case_paths = Dir[File.join(CASES_DIR, "*.json")].sort
      abort "No generated receipt cases found in #{CASES_DIR}" if case_paths.empty?

      failures = []
      case_paths.each do |path|
        case_data = Validator.load_file(path)
        result = Validator.call(case_data)
        if result.valid?
          puts "PASS #{File.basename(path)}"
          write_text_file(case_data) if write_text
        else
          failures << [ path, result.errors ]
          puts "FAIL #{File.basename(path)}"
          result.errors.each { |error| puts "  - #{error}" }
        end
      end

      abort "#{failures.size} generated receipt case(s) failed validation" if failures.any?
      puts "#{case_paths.size} generated receipt case(s) passed"
    end

    private

    attr_reader :argv

    def write_text_file(case_data)
      FileUtils.mkdir_p(TEXT_DIR)
      path = File.join(TEXT_DIR, "#{case_data.fetch('case_id')}.txt")
      File.write(path, TextRenderer.call(case_data))
    end
  end
end
