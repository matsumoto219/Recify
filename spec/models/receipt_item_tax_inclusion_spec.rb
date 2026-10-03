require 'rails_helper'

RSpec.describe ReceiptItem, type: :model do
  let(:receipt) { build(:receipt) }
  let(:base_attributes) do
    {
      confirmed_name: '税区分確認商品',
      quantity: 2,
      quantity_unit_code: 'each',
      price: 100,
      original_line_total: 200,
      line_total: 200,
      tax_rate: BigDecimal('0.1')
    }
  end

  def build_item(attributes = {})
    receipt.receipt_items.build(base_attributes.merge(attributes))
  end

  def reference_attributes
    {
      pricing_source_kind: 'reference_quantity_price',
      price: nil,
      quantity: BigDecimal('250'),
      quantity_unit_code: 'gram',
      reference_price_amount: BigDecimal('100'),
      reference_quantity: BigDecimal('100'),
      reference_quantity_unit_code: 'gram',
      reference_price_tax_inclusion: 'net'
    }
  end

  describe 'input tax inclusion contract' do
    it '新しい値がすべてNULLの旧sourceを引き続き許可する' do
      [ nil, 'count_unit_price', 'explicit_line_total' ].each do |kind|
        item = build_item(pricing_source_kind: kind)

        expect(item).to be_valid
        expect(item.input_tax_inclusion).to be_nil
        expect(item.tax_inclusion_origin).to be_nil
        expect(item.gross_line_total).to be_nil
      end
      expect(build_item(reference_attributes)).to be_valid
    end

    it 'countとexplicitでgrossとnetおよびサーバー由来を許可する' do
      %w[count_unit_price explicit_line_total].product(%w[gross net]).each do |kind, basis|
        item = build_item(pricing_source_kind: kind, input_tax_inclusion: basis, tax_inclusion_origin: 'manual')

        expect(item).to be_valid
      end
    end

    it '許可された由来codeをすべて保持する' do
      ReceiptCalculationSettings::ORIGINS.each do |origin|
        item = build_item(pricing_source_kind: 'count_unit_price', input_tax_inclusion: 'gross', tax_inclusion_origin: origin)

        expect(item).to be_valid
        expect(item.tax_inclusion_origin).to eq(origin)
      end
    end

    it 'referenceは専用税区分だけを正本として由来を保持する' do
      item = build_item(reference_attributes.merge(tax_inclusion_origin: 'analysis'))

      expect(item).to be_valid
      expect(item.input_tax_inclusion).to be_nil
      expect(item.reference_price_tax_inclusion).to eq('net')
    end

    it 'explicitの入力税区分とreference diagnosticの税区分を混同しない' do
      item = build_item(
        pricing_source_kind: 'explicit_line_total',
        input_tax_inclusion: 'gross',
        tax_inclusion_origin: 'manual',
        reference_price_amount: BigDecimal('100'),
        reference_quantity: BigDecimal('100'),
        reference_quantity_unit_code: 'gram',
        reference_price_tax_inclusion: 'net'
      )

      expect(item).to be_valid
      expect(item.input_tax_inclusion).to eq('gross')
      expect(item.reference_price_tax_inclusion).to eq('net')
    end

    it 'legacy kindのまま入力税区分だけを保存しない' do
      item = build_item(input_tax_inclusion: 'gross', tax_inclusion_origin: 'manual')

      expect(item).not_to be_valid
      expect(item.errors.of_kind?(:input_tax_inclusion, :invalid)).to be(true)
    end

    it 'referenceに二つ目の税区分正本を作らない' do
      item = build_item(reference_attributes.merge(input_tax_inclusion: 'net', tax_inclusion_origin: 'manual'))

      expect(item).not_to be_valid
      expect(item.errors.of_kind?(:input_tax_inclusion, :invalid)).to be(true)
    end

    it 'countとexplicitの入力税区分に由来を必須とする' do
      %w[count_unit_price explicit_line_total].each do |kind|
        item = build_item(pricing_source_kind: kind, input_tax_inclusion: 'gross')

        expect(item).not_to be_valid
        expect(item.errors.of_kind?(:tax_inclusion_origin, :blank)).to be(true)
      end
    end

    it '入力税区分のないcount・explicit・legacyの由来だけを保存しない' do
      [ nil, 'count_unit_price', 'explicit_line_total' ].each do |kind|
        item = build_item(pricing_source_kind: kind, tax_inclusion_origin: 'manual')

        expect(item).not_to be_valid
        expect(item.errors.of_kind?(:tax_inclusion_origin, :invalid)).to be(true)
      end
    end

    it 'referenceの由来を有効な専用税区分へ結び付ける' do
      item = build_item(reference_attributes.merge(reference_price_tax_inclusion: nil, tax_inclusion_origin: 'analysis'))

      expect(item).not_to be_valid
      expect(item.errors.of_kind?(:tax_inclusion_origin, :invalid)).to be(true)
    end

    it '未知・blank・大文字の税区分と由来を補正しない' do
      [ '', 'GROSS', 'gross ', 'tax_included', false ].each do |basis|
        item = build_item(pricing_source_kind: 'count_unit_price', input_tax_inclusion: basis, tax_inclusion_origin: 'manual')

        expect(item).not_to be_valid
        expect(item.errors.of_kind?(:input_tax_inclusion, :inclusion)).to be(true)
      end
      [ '', 'MANUAL', 'manual ', 'unknown', false ].each do |origin|
        item = build_item(pricing_source_kind: 'count_unit_price', input_tax_inclusion: 'gross', tax_inclusion_origin: origin)

        expect(item).not_to be_valid
        expect(item.errors.of_kind?(:tax_inclusion_origin, :inclusion)).to be(true)
      end
    end
  end

  describe 'gross line total validation' do
    it 'NULL・0・整数の税込参考額を元金額へ逆流させない' do
      [ nil, 0, 220 ].each do |gross_total|
        item = build_item(gross_line_total: gross_total)

        expect(item).to be_valid
        expect(item.gross_line_total).to eq(gross_total)
        expect(item.line_total).to eq(200)
        expect(item.original_line_total).to eq(200)
        expect(item.price).to eq(100)
      end
    end

    it '負数・小数・blank・型違いを拒否する' do
      [ -1, '1.5', '', 'not-an-amount', false ].each do |gross_total|
        item = build_item(gross_line_total: gross_total)

        expect(item).not_to be_valid
        expect(item.errors[:gross_line_total]).to be_present
      end
    end

    it '既存の明細金額runtime上限を維持する' do
      allow(ReceiptAmountService).to receive(:receipt_item_line_total_max).and_return(500)
      item = build_item(gross_line_total: 501)

      expect(item).not_to be_valid
      expect(item.errors.of_kind?(:gross_line_total, :less_than_or_equal_to)).to be(true)
      expect(build_item(gross_line_total: 500)).to be_valid
    end

    it 'runtime上限にかかわらず固定安全上限を超えない' do
      allow(ReceiptAmountService).to receive(:receipt_item_line_total_max).and_return(1_000_000_000_000)

      expect(build_item(gross_line_total: 999_999_999_999)).to be_valid
      item = build_item(gross_line_total: 1_000_000_000_000)
      expect(item).not_to be_valid
      expect(item.errors.of_kind?(:gross_line_total, :less_than_or_equal_to)).to be(true)
    end
  end
end
