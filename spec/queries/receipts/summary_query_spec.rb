require 'rails_helper'

RSpec.describe Receipts::SummaryQuery do
  include ActiveSupport::Testing::TimeHelpers

  def create_item(receipt, category:, line_total:, name: '商品')
    receipt.receipt_items.create!(
      raw_text: name,
      confirmed_name: name,
      category: category,
      quantity: 1,
      quantity_unit_code: 'each',
      price: line_total,
      line_total: line_total,
      position_index: receipt.receipt_items.count + 1
    )
  end

  def count_sql_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      queries << sql unless payload[:name] == 'SCHEMA' || sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end

  it 'returns immutable headline counts scoped to the user by default' do
    user = create(:user)
    create(:receipt, :completed, user: user, total_amount: 1000)
    create(:receipt, :processing, :with_image, user: user, total_amount: 2000)
    create(:receipt, :review_needed, user: user, total_amount: 3000)
    create(:receipt, :failed, user: user, total_amount: 4000)
    create(:receipt, :failed, user: create(:user), total_amount: 5000)

    result = described_class.call(user: user)

    aggregate_failures do
      expect(result).to be_frozen
      expect(result).to have_attributes(
        receipts_count: 4,
        overall_total: 4000,
        processing_count: 1,
        review_needed_count: 1,
        failed_count: 1
      )
      expect { result.failed_count = 0 }.to raise_error(NoMethodError)
    end
  end

  it 'returns zero values for an explicitly empty scope' do
    user = create(:user)

    result = described_class.call(user: user, scope: Receipt.none)

    expect(result.to_h.slice(
      :receipts_count,
      :current_month_total,
      :previous_month_total,
      :overall_total,
      :processing_count,
      :review_needed_count,
      :failed_count
    ).values).to all(eq(0))
  end

  it 'loads all headline aggregates with one receipt query' do
    user = create(:user)
    create(:receipt, :completed, user: user, total_amount: 1000)
    create(:receipt, :failed, user: user, total_amount: 2000)

    result = nil
    queries = count_sql_queries { result = described_class.call(user: user) }
    receipt_queries = queries.select { |sql| sql.include?('FROM "receipts"') }

    aggregate_failures do
      expect(receipt_queries.size).to eq(1)
      expect(result.receipts_count).to eq(2)
      expect(result.overall_total).to eq(1000)
    end
  end

  it 'preserves monthly change labels for current and previous month totals' do
    user = create(:user)
    current_month = Time.zone.local(2026, 5, 16, 12)
    previous_month = Time.zone.local(2026, 4, 16, 12)

    travel_to(current_month) do
      create(:receipt, :completed, user: user, total_amount: 3000, purchased_at: current_month)
      create(:receipt, :completed, user: user, total_amount: 1500, purchased_at: previous_month)

      result = described_class.call(user: user)

      aggregate_failures do
        expect(result.current_month_total).to eq(3000)
        expect(result.previous_month_total).to eq(1500)
        expect(result.monthly_change_label).to eq(
          I18n.t('dashboard.summary.amount.monthly_change', value: '+100')
        )
        expect(result.monthly_change_icon).to eq('trending_up')
      end
    end
  end

  it 'aggregates completed and review-needed item categories and normalizes blanks' do
    user = create(:user)
    receipt = create(:receipt, :completed, user: user)
    review_needed = create(:receipt, :review_needed, user: user)
    failed = create(:receipt, :failed, user: user)
    create_item(receipt, category: nil, line_total: 100)
    create_item(receipt, category: '', line_total: 200)
    create_item(review_needed, category: 'food', line_total: 500)
    create_item(failed, category: 'food', line_total: 9000)

    result = described_class.categories(user: user)

    expect(result).to contain_exactly(
      hash_including(category: 'food', label: '食品', total_amount: 500, item_count: 1),
      hash_including(
        category: 'uncategorized',
        label: I18n.t('receipts.item_fields.uncategorized'),
        total_amount: 300,
        item_count: 2
      )
    )
  end

  it 'reapplies the user boundary to category aggregation even with a broader scope' do
    user = create(:user)
    own = create(:receipt, :completed, user: user)
    other = create(:receipt, :completed, user: create(:user))
    create_item(own, category: 'food', line_total: 500)
    create_item(other, category: 'food', line_total: 10_000)

    result = described_class.categories(user: user, scope: Receipt.all)

    expect(result).to contain_exactly(hash_including(category: 'food', total_amount: 500, item_count: 1))
  end
end
