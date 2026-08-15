require 'rails_helper'

RSpec.describe Ocr::ResultTemplate do
  describe '.empty_candidates' do
    it 'always exposes an empty reference-pricing candidate collection' do
      expect(described_class.empty_candidates[:reference_pricing_candidates]).to eq([])
    end
  end

  describe '.error_result' do
    it 'returns a fresh reference-pricing candidate collection for every error' do
      first = described_class.error_result(error_code: 'ocr_api_error', provider: 'azure_document_intelligence')
      second = described_class.error_result(error_code: 'ocr_api_error', provider: 'azure_document_intelligence')

      first.dig(:candidates, :reference_pricing_candidates) << { candidate_id: 'mutated' }

      expect(second.dig(:candidates, :reference_pricing_candidates)).to eq([])
    end
  end
end
