require 'rails_helper'

RSpec.describe Receipts::SearchForm do
  describe '.call' do
    it '完全入力された不正なdate演算子をinvalidにする' do
      invalid_queries = [
        'date>=2026-13-01',
        'date>=2026-02-31',
        'date<=2000-22-21',
        'date:2026-01-01..2026-13-40'
      ]

      aggregate_failures do
        invalid_queries.each do |query|
          result = described_class.call(query)

          expect(result).to be_frozen
          expect(result).not_to be_valid
          expect(result.error_code).to eq('invalid_search_query')
        end
      end
    end

    it '入力途中やdate以外のtokenはvalid扱いにする' do
      valid_queries = [
        'date>=2026-',
        'date<=2214-15-',
        'date:2026-01-01..',
        'date:..2026-01-31',
        'amount>=',
        '<=',
        'amount>=abc',
        'date>=abcd',
        'unknown:xxx'
      ]

      aggregate_failures do
        valid_queries.each do |query|
          expect(described_class.call(query)).to be_valid
        end
      end
    end
  end
end
