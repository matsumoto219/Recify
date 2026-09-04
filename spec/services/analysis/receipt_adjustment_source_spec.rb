require 'rails_helper'

RSpec.describe Analysis::ReceiptBuildParamsService do
  def adjustment_ocr_result(lines:, items: [], candidates: [])
    {
      candidates: { country_region: 'JPN', items: items, adjustment_candidates: candidates },
      lines: lines
    }
  end

  it '同じ物理行のAIとOCR割引は英字大小文字や空白の差で二重保存しない' do
    ocr = adjustment_ocr_result(
      lines: [ '検証品A 360円', 'Sample Stock Discount -180', '合計 180円' ],
      items: [ { raw_text: '検証品A', line_total: 360 }, { raw_text: 'Sample Stock Discount', line_total: -180 } ]
    )
    ai = {
      receipt_adjustments_attributes: [
        {
          kind: 'receipt_discount',
          label: 'sample stock discount',
          amount: 180,
          sign: 'discount',
          source_text: 'sample  stock discount',
          source_line_index: 1
        }
      ]
    }

    result = described_class.call(ocr_result: ocr, ai_result: ai)

    expect(result[:receipt_adjustments_attributes]).to contain_exactly(
      include(kind: 'receipt_discount', amount: 180, source: 'ai')
    )
    expect(result[:receipt_items_attributes]).to contain_exactly(include(line_total: 360))
  end

  it '割引率だけが印字された行から同じ値のAI税率を採用しない' do
    [ 1, 8, 27, 99 ].each do |percentage|
      ocr = adjustment_ocr_result(lines: [ '検証品A 1000円', '小計 1000円', "クーポン #{percentage}%", '-100円', '合計 900円' ])
      ai = {
        receipt_adjustments_attributes: [
          {
            kind: 'coupon',
            label: "クーポン #{percentage}%",
            amount: 100,
            sign: 'discount',
            tax_rate: BigDecimal(percentage) / 100,
            source_text: "クーポン #{percentage}%",
            source_line_index: 2
          }
        ]
      }

      result = described_class.call(ocr_result: ocr, ai_result: ai)

      expect(result[:receipt_adjustments_attributes]).to contain_exactly(include(amount: 100))
      expect(result[:receipt_adjustments_attributes].sole[:tax_rate]).to be_nil
    end
  end

  it '割引labelと率が別行でも割引率を税率にしない' do
    ocr = adjustment_ocr_result(lines: [ '小計 1000円', '会員割引', '27%', '-270円', '合計 730円' ])
    ai = {
      receipt_adjustments_attributes: [
        {
          kind: 'receipt_discount',
          label: '会員割引',
          amount: 270,
          sign: 'discount',
          tax_rate: 0.27,
          source_text: '27%',
          source_line_index: 2
        }
      ]
    }

    result = described_class.call(ocr_result: ocr, ai_result: ai)

    expect(result[:receipt_adjustments_attributes]).to contain_exactly(include(amount: 270))
    expect(result[:receipt_adjustments_attributes].sole[:tax_rate]).to be_nil
  end

  it '料金の加算率を税率として推定しない' do
    ocr = adjustment_ocr_result(lines: [ '小計 1000円', '深夜料金10%', '100円', '合計 1100円' ])
    ai = {
      receipt_adjustments_attributes: [
        {
          kind: 'late_night_charge',
          label: '深夜料金10%',
          amount: 100,
          sign: 'surcharge',
          source_text: '深夜料金10%',
          source_line_index: 1
        }
      ]
    }

    result = described_class.call(ocr_result: ocr, ai_result: ai)

    expect(result[:receipt_adjustments_attributes]).to contain_exactly(include(amount: 100))
    expect(result[:receipt_adjustments_attributes].sole[:tax_rate]).to be_nil
  end

  it '明示された調整の税率は割引率と混同して除外しない' do
    ocr = adjustment_ocr_result(lines: [ '小計 1000円', '配送料 税率27% 100円', '合計 1100円' ])
    ai = {
      receipt_adjustments_attributes: [
        {
          kind: 'delivery_fee',
          label: '配送料 税率27%',
          amount: 100,
          sign: 'surcharge',
          tax_rate: 0.27,
          source_text: '配送料 税率27% 100円',
          source_line_index: 1
        }
      ]
    }

    result = described_class.call(ocr_result: ocr, ai_result: ai)

    expect(result[:receipt_adjustments_attributes]).to contain_exactly(include(amount: 100, tax_rate: BigDecimal('0.27')))
  end
end
