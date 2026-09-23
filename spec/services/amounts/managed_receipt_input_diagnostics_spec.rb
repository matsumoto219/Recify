require 'rails_helper'

RSpec.describe ReceiptAmountService, 'managed receipt input diagnostics' do
  def calculate(receipt:, context: :manual)
    settings = {
      'schema_version' => 1,
      'tax_rounding_mode' => { 'value' => 'floor', 'origin' => 'manual' },
      'discount_rounding_mode' => { 'value' => 'round', 'origin' => 'manual' },
      'tax_rounding_scope' => { 'value' => 'per_tax_rate_group', 'origin' => 'manual' }
    }
    described_class.call(
      receipt: receipt.merge(calculation_settings: settings),
      receipt_items: [
        {
          pricing_source_kind: 'count_unit_price',
          input_tax_inclusion: 'gross',
          price: 100,
          quantity: 1,
          quantity_unit_code: 'each',
          tax_rate: BigDecimal('0.1')
        }
      ],
      receipt_tax_details: [],
      context: context
    )
  end

  [ { total_amount: 100 }, { subtotal_amount: 100, tax_amount: 100, total_amount: 100 } ].each do |receipt|
    it "明示設定でも不整合な#{receipt.keys.join('/')}の診断を失わず、入力合計をwinnerにしない" do
      result = calculate(receipt: receipt)

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 91, tax: 9, total: 100)
        expect(result[:review_reasons]).to include('invalid_amount_relation')
        expect(result[:safe_to_auto_complete]).to be(false)
        expect(result.dig(:amount_engine, :selected_candidate, :basis)).to eq('items_as_tax_included')
        expect(result.dig(:amount_engine, :candidates).map { |candidate| candidate[:basis] }.uniq).to eq([ 'items_as_tax_included' ])
      end
    end
  end

  it '入力合計の診断は選択後に付与し、候補のscoreを変更しない' do
    result = calculate(receipt: { total_amount: 100 })

    expect(result.dig(:amount_engine, :selected_candidate, :warnings)).to include(:invalid_amount_relation)
    expect(result.dig(:amount_engine, :selected_candidate, :score)).to eq(0)
    expect(result.dig(:amount_engine, :selected_candidate, :score_breakdown, :warning_penalty)).to eq(0)
  end

  [ {}, { subtotal_amount: 91, tax_amount: 9, total_amount: 100 } ].each do |receipt|
    it "矛盾がない#{receipt.keys.join('/').presence || '未送信合計'}へ不整合reviewを増やさない" do
      result = calculate(receipt: receipt)

      expect(result[:resolved]).to include(subtotal: 91, tax: 9, total: 100)
      expect(result[:review_reasons]).not_to include('invalid_amount_relation')
      expect(result[:needs_review]).to be(false)
    end
  end

  it '金額変更に伴い未送信扱いとなった旧Receipt合計へ不整合reviewを復活させない' do
    result = calculate(
      context: :edit_save,
      receipt: {
        subtotal_amount: 100,
        tax_amount: 100,
        total_amount: 100,
        amount_subtotal_amount_submitted: false,
        amount_tax_amount_submitted: false,
        amount_total_amount_submitted: false,
        amount_tax_rate_submitted: false
      }
    )

    expect(result[:resolved]).to include(subtotal: 91, tax: 9, total: 100)
    expect(result[:review_reasons]).not_to include('invalid_amount_relation')
  end
end
