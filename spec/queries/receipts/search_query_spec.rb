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
