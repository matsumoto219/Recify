require 'rails_helper'

RSpec.describe Search do
  describe '.validate_query' do
    it 'QueryValidatorへ委譲する親入口である' do
      result = Search::QueryValidator::Result.new(valid: true)

      allow(Search::QueryValidator).to receive(:call).with('date>=2026-01-01').and_return(result)

      expect(described_class.validate_query('date>=2026-01-01')).to eq(result)
    end
  end
end
