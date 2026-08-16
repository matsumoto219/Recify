# frozen_string_literal: true

require "fileutils"
require_relative "../../duplicate_files"
require_relative "../../generated_receipts"

module GeneratedReceipts
  module AdoptionEvidence
    class Cli
      def self.call(argv)
        new(argv).call
      end

      def initialize(argv)
        @argv = argv
      end

      def call
        DuplicateFiles.verify_repository!(root: File.expand_path("../../..", __dir__))
        paths = GeneratedReceipts.adoption_evidence_case_paths
        abort "No adoption evidence cases found" if paths.empty?

        validated_cases = []
        failures = paths.filter_map do |path|
          failure, case_data = validate_case(path)
          validated_cases << case_data if case_data
          failure
        end
        abort "#{failures.size} adoption evidence case(s) failed validation" if failures.any?

        validated_cases.each do |case_data|
          write_text(case_data) if argv.include?("--write-text")
          write_image(case_data) if argv.include?("--write-images")
        end
        puts "#{paths.size} adoption evidence case(s) passed"
      rescue DuplicateFiles::Error => error
        abort error.message
      end

      private

      attr_reader :argv

      def validate_case(path)
        case_data = Validator.load_file(path)
        result = Validator.call(case_data)
        unless result.valid?
          puts "FAIL #{File.basename(path)}"
          result.errors.each { |error| puts "  - #{error}" }
          return [ [ path, result.errors ], nil ]
        end

        puts "PASS #{File.basename(path)}"
        [ nil, case_data ]
      rescue Validator::FixtureLoadError => error
        puts "FAIL adoption evidence fixture"
        puts "  - #{error.message}"
        [ [ path, [ error.message ] ], nil ]
      end

      def write_text(case_data)
        FileUtils.mkdir_p(GeneratedReceipts::ADOPTION_EVIDENCE_TEXT_DIR)
        path = GeneratedReceipts::Validator.artifact_path(
          root: GeneratedReceipts::ADOPTION_EVIDENCE_TEXT_DIR,
          case_id: case_data.fetch("case_id"),
          extension: "txt"
        )
        File.write(path, TextRenderer.call(case_data))
      end

      def write_image(case_data)
        FileUtils.mkdir_p(GeneratedReceipts::ADOPTION_EVIDENCE_IMAGES_DIR)
        path = GeneratedReceipts::Validator.artifact_path(
          root: GeneratedReceipts::ADOPTION_EVIDENCE_IMAGES_DIR,
          case_id: case_data.fetch("case_id"),
          extension: "png"
        )
        PngRenderer.call(case_data, output_path: path)
      end
    end
  end
end
