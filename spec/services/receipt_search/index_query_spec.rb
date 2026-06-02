require 'rails_helper'

RSpec.describe ReceiptSearch::IndexQuery do
  let(:user) { create(:user) }

  def call_query(scope: user.receipts, query: '', sort: nil, per_page: nil)
    described_class.call(scope:, query:, sort:, per_page:)
  end

  describe '.call' do
    it 'invalid sort/per_pageはdefaultへfallbackし、sanitized paramsへ残さない' do
      result = call_query(sort: 'created_at;drop', per_page: '999')

      aggregate_failures do
        expect(result.sort).to eq('newest')
        expect(result.per_page).to eq(20)
        expect(result.sanitized_params).to eq({})
        expect(result).to be_default_index_view
      end
    end

    it 'queryと非default sort/per_pageをsanitized paramsへ含める' do
      result = call_query(query: 'コーヒー', sort: 'oldest', per_page: '50')

      aggregate_failures do
        expect(result.sort).to eq('oldest')
        expect(result.per_page).to eq(50)
        expect(result.sanitized_params).to eq(q: 'コーヒー', sort: 'oldest', per_page: '50')
        expect(result.pagination_params).to eq(result.sanitized_params)
        expect(result).not_to be_default_index_view
      end
    end

    it 'queryを検索scopeへ適用する' do
      coffee = create(:receipt, :completed, user:, store_name: 'コーヒーストア')
      create(:receipt, :completed, user:, store_name: '食品ストア')

      result = call_query(query: 'コーヒー')

      expect(result.scope).to contain_exactly(coffee)
    end

    it 'newestは作成日時の降順を維持する' do
      older = create(:receipt, :completed, user:, created_at: 2.days.ago)
      newer = create(:receipt, :completed, user:, created_at: 1.hour.ago)

      result = call_query(sort: 'newest')

      expect(result.scope.to_a).to eq([ newer, older ])
    end

    it 'oldestは作成日時の昇順にする' do
      older = create(:receipt, :completed, user:, created_at: 2.days.ago)
      newer = create(:receipt, :completed, user:, created_at: 1.hour.ago)

      result = call_query(sort: 'oldest')

      expect(result.scope.to_a).to eq([ older, newer ])
    end

    it 'amount_desc/amount_ascはnil金額を最後にする' do
      low = create(:receipt, :completed, user:, total_amount: 100)
      high = create(:receipt, :completed, user:, total_amount: 300)
      nil_amount = create(:receipt, :completed, user:, total_amount: 200)
      nil_amount.update_columns(total_amount: nil)

      aggregate_failures do
        expect(call_query(sort: 'amount_desc').scope.to_a).to eq([ high, low, nil_amount ])
        expect(call_query(sort: 'amount_asc').scope.to_a).to eq([ low, high, nil_amount ])
      end
    end

    it 'store_nameはnil/blank店名を最後にして昇順にする' do
      beta = create(:receipt, :completed, user:, store_name: 'Beta')
      alpha = create(:receipt, :completed, user:, store_name: 'Alpha')
      nil_store = create(:receipt, :completed, user:, store_name: 'Gamma')
      blank_store = create(:receipt, :completed, user:, store_name: 'Delta')
      nil_store.update_columns(store_name: nil)
      blank_store.update_columns(store_name: '')

      result = call_query(sort: 'store_name')

      expect(result.scope.to_a).to eq([ alpha, beta, blank_store, nil_store ])
    end

    it 'updatedは更新日時の降順にする' do
      older = create(:receipt, :completed, user:, updated_at: 2.days.ago)
      newer = create(:receipt, :completed, user:, updated_at: 1.hour.ago)

      result = call_query(sort: 'updated')

      expect(result.scope.to_a).to eq([ newer, older ])
    end

    it 'review_priorityは要確認を優先し、その中では作成日時の降順にする' do
      completed_newer = create(:receipt, :completed, user:, created_at: 30.minutes.ago)
      review_older = create(:receipt, :review_needed, user:, created_at: 2.days.ago)
      review_newer = create(:receipt, :review_needed, user:, created_at: 1.hour.ago)

      result = call_query(sort: 'review_priority')

      expect(result.scope.to_a).to eq([ review_newer, review_older, completed_newer ])
    end
  end
end
