# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../duplicate_files"
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
      DuplicateFiles.verify_repository!(root: File.expand_path("../..", __dir__))
      write_text = argv.include?("--write-text")
      write_images = argv.include?("--write-images")
      case_paths = GeneratedReceipts.case_paths
      abort "No generated receipt cases found in #{CASES_DIR}" if case_paths.empty?

      failures = []
      case_paths.each do |path|
        begin
          case_data = Validator.load_file(path)
          result = Validator.call(case_data)
          if result.valid?
            write_text_file(case_data) if write_text
            write_image_file(case_data) if write_images
            puts "PASS #{File.basename(path)}"
          else
            failures << [ path, result.errors ]
            puts "FAIL #{File.basename(path)}"
            result.errors.each { |error| puts "  - #{error}" }
          end
        rescue Validator::FixtureLoadError => error
          failures << [ path, [ error.message ] ]
          puts "FAIL generated receipt fixture"
          puts "  - #{error.message}"
        end
      end

      abort "#{failures.size} generated receipt case(s) failed validation" if failures.any?
      puts "#{GeneratedReceipts.legacy_case_paths.size} existing generated receipt case(s) passed"
      puts "#{GeneratedReceipts.measurement_case_paths.size} Measurement generated receipt case(s) passed"
      puts "#{case_paths.size} generated receipt case(s) passed"
    rescue DuplicateFiles::Error => error
      abort error.message
    end

    private

    attr_reader :argv

    def write_text_file(case_data)
      FileUtils.mkdir_p(TEXT_DIR)
      path = Validator.artifact_path(
        root: TEXT_DIR,
        case_id: case_data.fetch("case_id"),
        extension: "txt"
      )
      File.write(path, TextRenderer.call(case_data))
    end

    def write_image_file(case_data)
      FileUtils.mkdir_p(IMAGES_DIR)
      path = Validator.artifact_path(
        root: IMAGES_DIR,
        case_id: case_data.fetch("case_id"),
        extension: "png"
      )
      PngRenderer.call(case_data, output_path: path)
    end
  end
end
