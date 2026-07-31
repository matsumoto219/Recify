require 'rails_helper'

RSpec.describe Receipts::SearchQuery do
  let(:user) { create(:user) }

  def search(query, scope: user.receipts)
    described_class.call(scope: scope, query: query)
  end

  def create_search_receipt(user: self.user, store_name:, total_amount:, purchased_at:, item_name: nil, **attributes)
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: store_name,
      total_amount: total_amount,
      purchased_at: purchased_at,
      **attributes
    )
    if item_name.present?
      receipt.receipt_items.create!(
        raw_text: item_name,
        confirmed_name: item_name,
        category: 'food',
        quantity: 1,
        quantity_unit_code: 'each',
        price: total_amount,
        line_total: total_amount,
        position_index: 1
      )
    end
    receipt
  end

  it 'returns the passed constrained scope for a blank query' do
    receipt = create_search_receipt(
      store_name: '対象店',
      total_amount: 100,
      purchased_at: Time.zone.local(2026, 1, 10)
    )
    constrained = user.receipts.where(id: receipt.id)

    expect(search('', scope: constrained)).to equal(constrained)
  end

  it 'keeps every text and amount branch inside the passed user scope' do
    target = create_search_receipt(
      store_name: '共通店',
      total_amount: 1000,
      purchased_at: Time.zone.local(2026, 1, 10)
    )
    create_search_receipt(
      user: create(:user),
      store_name: '共通店',
      total_amount: 1000,
      purchased_at: Time.zone.local(2026, 1, 10)
    )

    expect(search('共通店 1000')).to contain_exactly(target)
  end

  it 'combines item text, amount, and date tokens with AND semantics' do
    target = create_search_receipt(
      store_name: '対象店',
      total_amount: 280,
      purchased_at: Time.zone.local(2026, 1, 20),
      item_name: '牛乳'
    )
    create_search_receipt(
      store_name: '高額店',
      total_amount: 480,
      purchased_at: Time.zone.local(2026, 1, 20),
      item_name: '牛乳'
    )
    create_search_receipt(
      store_name: '古い店',
      total_amount: 280,
      purchased_at: Time.zone.local(2025, 12, 31),
      item_name: '牛乳'
    )

    expect(search('牛乳 <=300 date>=2026-01-01')).to contain_exactly(target)
  end

  it 'combines multiple ordinary text tokens with AND semantics' do
    target = create_search_receipt(
      store_name: '青空スーパー',
      total_amount: 100,
      purchased_at: Time.zone.local(2026, 1, 10),
      memo: '週末まとめ買い'
    )
    create_search_receipt(
      store_name: '青空スーパー',
      total_amount: 200,
      purchased_at: Time.zone.local(2026, 1, 11),
      memo: '平日の買い物'
    )
    create_search_receipt(
      store_name: '別の店',
      total_amount: 300,
      purchased_at: Time.zone.local(2026, 1, 12),
      memo: '週末まとめ買い'
    )

    expect(search('青空 週末')).to contain_exactly(target)
  end

  it 'supports exact, one-sided, and range date operators' do
    january_10 = create_search_receipt(
      store_name: '1/10',
      total_amount: 100,
      purchased_at: Time.zone.local(2026, 1, 10, 12)
    )
    january_20 = create_search_receipt(
      store_name: '1/20',
      total_amount: 100,
      purchased_at: Time.zone.local(2026, 1, 20, 12)
    )
    february = create_search_receipt(
      store_name: '2/1',
      total_amount: 100,
      purchased_at: Time.zone.local(2026, 2, 1, 12)
    )

    aggregate_failures do
      expect(search('2026-01-10')).to contain_exactly(january_10)
      expect(search('date>=2026-01-15')).to contain_exactly(january_20, february)
      expect(search('date<=2026-01-10')).to contain_exactly(january_10)
      expect(search('date:2026/01/01..2026/01/31')).to contain_exactly(january_10, january_20)
    end
  end

  it 'returns no matches without raising for invalid or partial date operators' do
    create_search_receipt(
      store_name: '日付店',
      total_amount: 100,
      purchased_at: Time.zone.local(2026, 1, 10)
    )

    aggregate_failures do
      %w[date>=2026-13-01 date<=2026-02-31 date:2026-01-01..2026-13-40 date>=2026-].each do |query|
        expect { search(query).load }.not_to raise_error
        expect(search(query)).to be_empty
      end
    end
  end

  it 'limits evaluation to the first five tokens' do
    receipt = create_search_receipt(
      store_name: 'one two three four five',
      total_amount: 100,
      purchased_at: Time.zone.local(2026, 1, 10)
    )

    expect(search('one two three four five missing')).to contain_exactly(receipt)
  end

  describe 'display ID token contract' do
    it 'matches an active receipt by exact display ID without treating ID-shaped text as a text match' do
      target = create_search_receipt(
        store_name: '対象店',
        total_amount: 100,
        purchased_at: Time.zone.local(2026, 1, 10),
        display_id: 'R-A1B2C3'
      )
      create_search_receipt(
        store_name: '別の店',
        total_amount: 200,
        purchased_at: Time.zone.local(2026, 1, 11),
        memo: '照会番号 R-A1B2C3',
        display_id: 'R-X9Y8Z7'
      )

      aggregate_failures do
        expect(search('R-A1B2C3', scope: user.receipts.active_for_user)).to contain_exactly(target)
        expect(search('r-a1b2c3', scope: user.receipts.active_for_user)).to contain_exactly(target)
        expect(search(" \tR-A1B2C3\n", scope: user.receipts.active_for_user)).to contain_exactly(target)
      end
    end

    it 'does not promote partial or wildcard display ID input to identity lookup' do
      create_search_receipt(
        store_name: '対象店',
        total_amount: 100,
        purchased_at: Time.zone.local(2026, 1, 10),
        display_id: 'R-A1B2C3'
      )
      text_match = create_search_receipt(
        store_name: '別の店',
        total_amount: 200,
        purchased_at: Time.zone.local(2026, 1, 11),
        memo: '照会番号 R-A1B2C3',
        display_id: 'R-X9Y8Z7'
      )

      aggregate_failures do
        expect(search('R-A1B2', scope: user.receipts.active_for_user)).to contain_exactly(text_match)
        expect(search('R-A1B2*', scope: user.receipts.active_for_user)).to be_empty
        expect(search('R-A1B2%', scope: user.receipts.active_for_user)).to be_empty
        expect(search('R-A1B2_', scope: user.receipts.active_for_user)).to be_empty
      end
    end

    it 'combines a display ID with existing store, memo, item, amount, and date tokens using AND' do
      target = create_search_receipt(
        store_name: '青空スーパー',
        total_amount: 1280,
        purchased_at: Time.zone.local(2026, 2, 3, 12),
        item_name: '特選牛乳',
        memo: '週末まとめ買い',
        display_id: 'R-AND123'
      )
      create_search_receipt(
        store_name: '青空スーパー',
        total_amount: 1280,
        purchased_at: Time.zone.local(2026, 2, 3, 12),
        item_name: '特選牛乳',
        memo: '週末まとめ買い',
        display_id: 'R-AND456'
      )

      aggregate_failures do
        expect(search('R-AND123 青空スーパー')).to contain_exactly(target)
        expect(search('r-and123 週末まとめ買い')).to contain_exactly(target)
        expect(search('R-AND123 特選牛乳')).to contain_exactly(target)
        expect(search('R-AND123 1280')).to contain_exactly(target)
        expect(search('R-AND123 2026-02-03')).to contain_exactly(target)
        expect(search('青空スーパー R-AND123')).to contain_exactly(target)
        expect(search('R-AND123 R-AND123')).to contain_exactly(target)
        expect(search('R-AND123 紅茶')).to be_empty
        expect(search('R-AND123 R-AND456')).to be_empty
      end
    end

    it 'counts display IDs in the existing first-five-token limit' do
      target = create_search_receipt(
        store_name: 'one two three four five',
        total_amount: 100,
        purchased_at: Time.zone.local(2026, 1, 10),
        display_id: 'R-LIMIT1'
      )

      aggregate_failures do
        expect(search('one two three four r-limit1 ignored')).to contain_exactly(target)
        expect(search('one two three four five R-Z9Y8X7')).to contain_exactly(target)
        expect(search('one two three four R-Z9Y8X7 R-LIMIT1')).to be_empty
      end
    end

    it 'keeps malformed R-like tokens on the existing text path' do
      short = create_search_receipt(
        store_name: '短いID風',
        total_amount: 100,
        purchased_at: Time.zone.local(2026, 1, 10),
        memo: '問い合わせ R-ABC',
        display_id: 'R-TEXT01'
      )
      long = create_search_receipt(
        store_name: '長いID風',
        total_amount: 200,
        purchased_at: Time.zone.local(2026, 1, 11),
        item_name: 'R-XYZWXYZ',
        display_id: 'R-TEXT02'
      )
      invalid_character = create_search_receipt(
        store_name: '記号 R-AB!123',
        total_amount: 300,
        purchased_at: Time.zone.local(2026, 1, 12),
        display_id: 'R-TEXT03'
      )

      aggregate_failures do
        expect(search('R-ABC')).to contain_exactly(short)
        expect(search('R-XYZWXYZ')).to contain_exactly(long)
        expect(search('R-AB!123')).to contain_exactly(invalid_character)
      end
    end

    it 'does not search the public ID column while preserving public-ID-shaped text matches' do
      public_id_owner = create_search_receipt(
        store_name: '公開ID所有者',
        total_amount: 100,
        purchased_at: Time.zone.local(2026, 1, 10),
        public_id: 'rcpt_AbCdEf1234567890',
        display_id: 'R-PUBLIC'
      )
      text_match = create_search_receipt(
        store_name: '公開IDメモ',
        total_amount: 200,
        purchased_at: Time.zone.local(2026, 1, 11),
        memo: '参照 rcpt_AbCdEf1234567890',
        display_id: 'R-PUBTXT'
      )

      result = search(public_id_owner.public_id)

      aggregate_failures do
        expect(result).to contain_exactly(text_match)
        expect(result).not_to include(public_id_owner)
      end
    end

    it 'keeps exact display ID lookup inside the passed active user scope' do
      target = create_search_receipt(
        store_name: '自分の対象',
        total_amount: 100,
        purchased_at: Time.zone.local(2026, 1, 10),
        display_id: 'R-SCOPE1'
      )
      other_user = create(:user)
      create_search_receipt(
        user: other_user,
        store_name: '他人の同一ID',
        total_amount: 200,
        purchased_at: Time.zone.local(2026, 1, 11),
        display_id: 'R-SCOPE1'
      )
      create_search_receipt(
        user: other_user,
        store_name: '他人だけのID',
        total_amount: 300,
        purchased_at: Time.zone.local(2026, 1, 12),
        display_id: 'R-OTHER1'
      )
      create(
        :receipt,
        :completed,
        :quarantined,
        user: user,
        store_name: '隔離ID',
        total_amount: 400,
        purchased_at: Time.zone.local(2026, 1, 13),
        display_id: 'R-QUAR01'
      )
      active_scope = user.receipts.active_for_user

      aggregate_failures do
        expect(search('R-SCOPE1', scope: active_scope)).to contain_exactly(target)
        expect(search('R-OTHER1', scope: active_scope)).to be_empty
        expect(search('R-QUAR01', scope: active_scope)).to be_empty
        expect(search('R-MISS01', scope: active_scope)).to be_empty
      end
    end

    it 'does not treat the internal numeric ID as an identity lookup' do
      target = create_search_receipt(
        store_name: '内部ID対象',
        total_amount: 987_654,
        purchased_at: Time.zone.local(2026, 1, 10),
        display_id: 'R-NUM001'
      )
      constrained = user.receipts.where(id: target.id)

      expect(search(target.id.to_s, scope: constrained)).to be_empty
    end

    it 'builds an exact display ID predicate without an item join or text OR and executes one query' do
      create_search_receipt(
        store_name: '対象店',
        total_amount: 100,
        purchased_at: Time.zone.local(2026, 1, 10),
        display_id: 'R-SQL001'
      )
      relation = search('r-sql001', scope: user.receipts.active_for_user)
      sql = relation.to_sql
      queries = []
      subscriber = lambda do |_name, _started, _finished, _id, payload|
        next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name].to_s)

        queries << payload[:sql] if payload[:sql].to_s.match?(/\ASELECT\b/i)
      end

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { relation.load }

      aggregate_failures do
        expect(relation.where_values_hash).to include('display_id' => 'R-SQL001')
        expect(sql).not_to include('ILIKE', 'receipt_items')
        expect(queries.size).to eq(1)
      end
    end
  end

  it 'removes ordering only from the matching id subquery' do
    sql = described_class.call(
      scope: user.receipts.order(created_at: :desc),
      query: 'コーヒー'
    ).to_sql

    aggregate_failures do
      expect(sql).to include('ORDER BY "receipts"."created_at" DESC')
      expect(sql.scan(/ORDER BY/).size).to eq(1)
    end
  end
end
