require 'rails_helper'

RSpec.describe ReceiptItem, type: :model do
  def legacy_profile(context: 'manual')
    {
      'schema_version' => 1,
      'context' => context,
      'selected_candidate_status' => 'accepted',
      'amount_engine' => {
        'schema_version' => 1,
        'selected_candidate_status' => 'accepted',
        'no_safe_candidate' => false,
        'selected_basis' => 'items_as_tax_excluded',
        'selected_candidate_id' => 'items_as_tax_excluded/floor/per_tax_rate_group',
        'selected_candidate' => {
          'candidate_id' => 'items_as_tax_excluded/floor/per_tax_rate_group',
          'basis' => 'items_as_tax_excluded',
          'rounding_mode' => 'floor',
          'rounding_scope' => 'per_tax_rate_group',
          'hard_reject_reasons' => []
        }
      }
    }
  end

  describe '#gross_amount_for_display' do
    it '記録された税込参考額を入力金額から独立して返し、0を欠損にしない' do
      item = described_class.new(line_total: 19, gross_line_total: 20, input_tax_inclusion: 'net')
      expect(item.gross_amount_for_display).to eq(20)
      item.gross_line_total = 0
      expect(item.gross_amount_for_display).to eq(0)
    end

    it '表示上限を超える値や負値を採用せず、不正な参考額をsourceで代用しない' do
      item = described_class.new(
        pricing_source_kind: 'explicit_line_total',
        line_total: 19,
        input_tax_inclusion: 'gross',
        tax_inclusion_origin: 'manual'
      )
      item.gross_line_total = described_class::GROSS_LINE_TOTAL_MAX
      expect(item.gross_amount_for_display).to eq(described_class::GROSS_LINE_TOTAL_MAX)

      [ -1, described_class::GROSS_LINE_TOTAL_MAX + 1 ].each do |amount|
        item.gross_line_total = amount
        expect(item.gross_amount_for_display).to be_nil
        item.gross_line_total = nil
        item.line_total = amount
        expect(item.gross_amount_for_display).to be_nil
      end
    end

    it '有効な選択中gross sourceだけはline_totalをそのまま使用できる' do
      %w[count_unit_price explicit_line_total].each do |kind|
        item = described_class.new(pricing_source_kind: kind, line_total: 19, input_tax_inclusion: 'gross', tax_inclusion_origin: 'manual')
        expect(item.gross_amount_for_display).to eq(19)
        item.input_tax_inclusion = 'net'
        expect(item.gross_amount_for_display).to be_nil
      end
      item = described_class.new(pricing_source_kind: 'reference_quantity_price', line_total: 19, reference_price_tax_inclusion: 'gross')
      expect(item.gross_amount_for_display).to eq(19)
    end

    it 'explicitに残るreference診断や無区分の旧行を税込authorityにしない' do
      item = described_class.new(pricing_source_kind: 'explicit_line_total', line_total: 19, reference_price_tax_inclusion: 'gross')
      expect(item.gross_amount_for_display).to be_nil
      expect(described_class.new(line_total: 0).gross_amount_for_display).to be_nil
    end

    it '旧manualの確定したItemAmounts投影と旧analysisの未分類投影だけを読み戻す' do
      receipt = Receipt.new(amount_calculation_profile: legacy_profile)
      item = described_class.new(pricing_source_kind: 'reference_quantity_price', reference_price_tax_inclusion: 'net', line_total: 20)
      expect(item.gross_amount_for_display(receipt: receipt)).to eq(20)

      receipt.amount_calculation_profile = legacy_profile(context: 'analysis')
      expect(item.gross_amount_for_display(receipt: receipt)).to be_nil
      item.pricing_source_kind = nil
      expect(item.gross_amount_for_display(receipt: receipt)).to eq(20)
      item.pricing_source_kind = 'count_unit_price'
      expect(item.gross_amount_for_display(receipt: receipt)).to be_nil
    end

    it '新条件、旧edit_save、不正・未知・rejectされたprofileをgross証拠にしない' do
      item = described_class.new(line_total: 20)
      invalid_profiles = [ nil, [], { 'schema_version' => 99 }, legacy_profile(context: 'edit_save') ]
      rejected = legacy_profile
      rejected['amount_engine']['selected_candidate_status'] = 'rejected'
      invalid_profiles << rejected
      mismatch = legacy_profile
      mismatch['amount_engine']['selected_candidate']['candidate_id'] = 'other'
      invalid_profiles << mismatch

      invalid_profiles.each do |profile|
        expect(item.gross_amount_for_display(receipt: Receipt.new(amount_calculation_profile: profile))).to be_nil
      end
      receipt = Receipt.new(
        amount_calculation_profile: legacy_profile,
        calculation_settings: {
          'schema_version' => 1,
          'tax_rounding_mode' => { 'value' => 'floor', 'origin' => 'manual' }
        }
      )
      expect(item.gross_amount_for_display(receipt: receipt)).to be_nil
    end

    it '関連Receiptを遅延取得せず、再計算も保存もしない' do
      item = described_class.new(receipt_id: 123, line_total: 20)
      expect(item).not_to receive(:receipt)
      expect(item).not_to receive(:save!)
      expect(ReceiptAmountService).not_to receive(:call)
      expect(item.gross_amount_for_display).to be_nil
    end

    it '読み込み済みのReceiptを使用しても属性やprofileを書き換えない' do
      receipt = Receipt.new(amount_calculation_profile: legacy_profile)
      item = receipt.receipt_items.build(line_total: 20)
      original_receipt_attributes = receipt.attributes.deep_dup
      original_item_attributes = item.attributes.deep_dup

      expect(item.gross_amount_for_display).to eq(20)
      expect(receipt.attributes).to eq(original_receipt_attributes)
      expect(item.attributes).to eq(original_item_attributes)
    end

    it '複数明細の表示でも関連取得や設定取得のqueryを追加しない' do
      receipt = create(:receipt, amount_calculation_profile: legacy_profile)
      3.times { receipt.receipt_items.create!(confirmed_name: '明細', line_total: 20) }
      items = described_class.where(receipt_id: receipt.id).to_a
      queries = []
      callback = ->(_name, _started, _finished, _id, payload) { queries << payload[:sql] }
      values = nil

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        values = items.map { |item| item.gross_amount_for_display(receipt: receipt) }
        expect(items.map(&:gross_amount_for_display)).to eq([ nil, nil, nil ])
      end

      expect(values).to eq([ 20, 20, 20 ])
      expect(queries).to be_empty
    end
  end
end
