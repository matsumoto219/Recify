require 'rails_helper'

RSpec.describe ReceiptSearch do
  describe '.validate_query' do
    it 'SearchFormへ委譲する親入口である' do
      result = Receipts::SearchForm::Result.new(valid: true)

      allow(Receipts::SearchForm).to receive(:call).with('date>=2026-01-01').and_return(result)

      expect(described_class.validate_query('date>=2026-01-01')).to eq(result)
    end
  end

  describe '.index_query' do
    it 'IndexQueryへ委譲する親入口である' do
      scope = Receipt.none
      result = Receipts::IndexQuery::Result.new(scope: scope, query: '', sort: 'newest', per_page: 20, sanitized_params: {})

      allow(Receipts::IndexQuery).to receive(:call).with(
        scope: scope,
        query: '',
        sort: 'newest',
        per_page: '20'
      ).and_return(result)

      expect(described_class.index_query(scope: scope, query: '', sort: 'newest', per_page: '20')).to eq(result)
    end
  end
end
