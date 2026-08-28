require 'rails_helper'
require_relative '../../../support/reference_pricing_profile_boundary_scanner'

RSpec.describe 'reference pricing profile boundary' do
  before(:context) do
    @scanner = ReferencePricingProfileBoundary::Scanner.new(root: Rails.root)
  end

  let(:scanner) { @scanner }

  it 'keeps country-specific detection lexemes and script constraints in the country profile' do
    details = scanner.violations.map do |violation|
      "#{violation.source_path}:#{violation.line}: #{violation.kind}: #{violation.source}"
    end

    aggregate_failures do
      expect(scanner.issues).to be_empty, scanner.issues.map(&:message).join("\n")
      expect(scanner.violations).to be_empty, details.join("\n")
      expect(scanner.scanned_paths).to match_array(%w[
        app/services/ocr/response_parser/item_calculation_mode_candidate_extractor.rb
        app/services/ocr/response_parser/reference_pricing_candidate_extractor.rb
        app/services/ocr/response_parser/reference_pricing_item_layout_extractor.rb
        app/services/ocr/response_parser/reference_pricing_line_group_extractor.rb
        app/services/ocr/response_parser/reference_pricing_single_item_gross_summary_evidence_extractor.rb
        app/services/ocr/response_parser/reference_pricing_strict_summary_total_extractor.rb
      ])
    end
  end
end
