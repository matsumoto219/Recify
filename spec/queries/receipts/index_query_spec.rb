require 'rails_helper'

RSpec.describe Receipts::IndexQuery do
  let(:user) { create(:user) }

  def call_query(scope: user.receipts, query: '', sort: nil, per_page: nil)
    described_class.call(scope:, query:, sort:, per_page:)
  end

  def captured_sql
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      queries << sql unless payload[:name] == 'SCHEMA' || sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end

  describe '.call' do
    it 'invalid sort/per_pageはdefaultへfallbackし、sanitized paramsへ残さない' do
      result = call_query(sort: 'created_at;drop', per_page: '999')

      aggregate_failures do
        expect(result).to be_frozen
        expect(result.sort).to eq('newest')
        expect(result.per_page).to eq(20)
        expect(result.sanitized_params).to eq({})
        expect(result).to be_default_index_view
      end
    end

    it 'blankやnon-scalarのsortは例外なくdefaultへfallbackする' do
      [ nil, '', [], {}, Object.new ].each do |sort|
        result = call_query(sort:)

        aggregate_failures do
          expect(result.sort).to eq('newest')
          expect(result.sanitized_params).to eq({})
          expect(result).to be_default_index_view
        end
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

    it 'lowercase display IDは比較時だけ正規化し、queryとURL用parameterは原文を維持する' do
      target = create(:receipt, :completed, user:, display_id: 'R-A1B2C3')

      result = call_query(scope: user.receipts.active_for_user, query: 'r-a1b2c3')

      aggregate_failures do
        expect(result.scope).to contain_exactly(target)
        expect(result.query).to eq('r-a1b2c3')
        expect(result.sanitized_params).to eq(q: 'r-a1b2c3')
      end
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

    it 'purchased_at_descは購入日時の降順、同日時とnilはid降順にする' do
      older = create(:receipt, :completed, user:, purchased_at: Time.zone.local(2026, 7, 10, 9, 0))
      newer = create(:receipt, :completed, user:, purchased_at: Time.zone.local(2026, 7, 12, 15, 0))
      tied_lower_id = create(:receipt, :completed, user:, purchased_at: Time.zone.local(2026, 7, 11, 12, 0))
      tied_higher_id = create(:receipt, :completed, user:, purchased_at: Time.zone.local(2026, 7, 11, 12, 0))
      nil_lower_id = create(:receipt, :completed, user:)
      nil_higher_id = create(:receipt, :completed, user:)
      nil_lower_id.update_column(:purchased_at, nil)
      nil_higher_id.update_column(:purchased_at, nil)

      result = call_query(sort: 'purchased_at_desc')

      expect(result.scope.to_a).to eq([
        newer,
        tied_higher_id,
        tied_lower_id,
        older,
        nil_higher_id,
        nil_lower_id
      ])
    end

    it 'purchased_at_ascは購入日時の昇順、同日時とnilはid昇順にする' do
      older = create(:receipt, :completed, user:, purchased_at: Time.zone.local(2026, 7, 10, 9, 0))
      newer = create(:receipt, :completed, user:, purchased_at: Time.zone.local(2026, 7, 12, 15, 0))
      tied_lower_id = create(:receipt, :completed, user:, purchased_at: Time.zone.local(2026, 7, 11, 12, 0))
      tied_higher_id = create(:receipt, :completed, user:, purchased_at: Time.zone.local(2026, 7, 11, 12, 0))
      nil_lower_id = create(:receipt, :completed, user:)
      nil_higher_id = create(:receipt, :completed, user:)
      nil_lower_id.update_column(:purchased_at, nil)
      nil_higher_id.update_column(:purchased_at, nil)

      result = call_query(sort: 'purchased_at_asc')

      expect(result.scope.to_a).to eq([
        older,
        tied_lower_id,
        tied_higher_id,
        newer,
        nil_lower_id,
        nil_higher_id
      ])
    end

    it '登録日時sortと購入日時sortの意味を分けて維持する' do
      recently_registered = create(
        :receipt,
        :completed,
        user:,
        created_at: 1.hour.ago,
        purchased_at: Time.zone.local(2026, 7, 1, 9, 0)
      )
      recently_purchased = create(
        :receipt,
        :completed,
        user:,
        created_at: 2.days.ago,
        purchased_at: Time.zone.local(2026, 7, 20, 9, 0)
      )

      aggregate_failures do
        expect(call_query(sort: 'newest').scope.to_a).to eq([ recently_registered, recently_purchased ])
        expect(call_query(sort: 'oldest').scope.to_a).to eq([ recently_purchased, recently_registered ])
        expect(call_query(sort: 'purchased_at_desc').scope.to_a).to eq([ recently_purchased, recently_registered ])
        expect(call_query(sort: 'purchased_at_asc').scope.to_a).to eq([ recently_registered, recently_purchased ])
      end
    end

    it '購入日時が同じでも両方向のpage境界で重複や欠落を起こさない' do
      purchased_at = Time.zone.local(2026, 7, 15, 12, 0)
      receipts = Array.new(25) { create(:receipt, :completed, user:, purchased_at:) }

      {
        'purchased_at_desc' => receipts.reverse,
        'purchased_at_asc' => receipts
      }.each do |sort, expected|
        result = call_query(sort:)
        page_one = result.scope.limit(20).to_a
        page_two = result.scope.offset(20).limit(20).to_a

        aggregate_failures do
          expect(page_one + page_two).to eq(expected)
          expect((page_one + page_two).map(&:id).uniq.size).to eq(receipts.size)
        end
      end
    end

    it '購入日時sortでも呼び出し元の利用者active scopeを維持する' do
      active = create(:receipt, :completed, user:, purchased_at: 2.days.ago)
      create(:receipt, :completed, :quarantined, user:, purchased_at: 1.day.ago)
      create(:receipt, :completed, purchased_at: Time.current)

      result = call_query(
        scope: user.receipts.active_for_user,
        sort: 'purchased_at_desc'
      )

      expect(result.scope.to_a).to eq([ active ])
    end

    it '空queryの購入日時sortは追加queryやitem joinを作らない' do
      create_list(:receipt, 3, :completed, user:)

      %w[purchased_at_desc purchased_at_asc].each do |sort|
        result = call_query(sort:)
        queries = captured_sql { result.scope.load }

        aggregate_failures do
          expect(queries.size).to eq(1)
          expect(queries.first).not_to include('receipt_items')
        end
      end
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
