require 'rails_helper'

RSpec.describe Analysis::ReceiptBuildParamsService do
  def adjustment_ocr_result(lines:, items: [], candidates: [])
    {
      candidates: { country_region: 'JPN', items: items, adjustment_candidates: candidates },
      lines: lines
    }
  end

  it '小計間の割引・数量・負額は種別や参照行が変わっても同じ印字済み割引を保持する' do
    lines = [ '検証品A 600円', '小計', '600円', '半額', '2', '-120円', '小計', '480円', '合計', '480円' ]
    ocr = adjustment_ocr_result(lines: lines, items: [ { raw_text: '検証品A', line_total: 600 } ])

    %w[receipt_discount other].each do |kind|
      [ 3, 4, 5 ].each do |source_index|
        result = described_class.call(
          ocr_result: ocr,
          ai_result: {
            receipt_adjustments_attributes: [
              {
                kind: kind,
                label: '半額',
                amount: 120,
                sign: 'discount',
                source_text: lines[source_index],
                source_line_index: source_index,
                needs_review: true,
                review_reasons: [ 'adjustment_uncertain' ]
              }
            ]
          }
        )

        expect(result[:receipt_adjustments_attributes]).to contain_exactly(
          include(kind: 'receipt_discount', amount: 120, sign: 'discount', needs_review: false, review_reasons: [])
        )
        expect(result[:receipt_items_attributes]).to contain_exactly(include(line_total: 600))
      end
    end
  end

  it '割引の所有権確定後も別の確認理由と印字額を保持する' do
    lines = [ '小計 600円', '半額', '2点', '-120円', '合計 480円' ]
    result = described_class.call(
      ocr_result: adjustment_ocr_result(lines: lines),
      ai_result: {
        receipt_adjustments_attributes: [
          {
            kind: 'other',
            amount: 120,
            sign: 'discount',
            source_line_index: 1,
            needs_review: true,
            review_reasons: [ 'adjustment_uncertain', 'adjustment_tax_rate_missing' ]
          }
        ]
      }
    )

    expect(result[:receipt_adjustments_attributes]).to contain_exactly(
      include(kind: 'receipt_discount', amount: 120, needs_review: true, review_reasons: [ 'adjustment_tax_rate_missing' ])
    )
  end

  it 'blockを持たない既存other調整のreview経路は変更しない' do
    result = described_class.call(
      ocr_result: adjustment_ocr_result(lines: [ '調整額 -120円' ]),
      ai_result: {
        receipt_adjustments_attributes: [
          { kind: 'other', amount: 120, sign: 'discount', source_line_index: 0 }
        ]
      }
    )

    expect(result[:receipt_adjustments_attributes]).to contain_exactly(
      include(kind: 'other', amount: 120, needs_review: true, review_reasons: [ 'adjustment_uncertain' ])
    )
  end

  it '明示spanの不正やnilを最終所有権解決まで維持し保存用attributesへ出さない' do
    lines = [ '小計 600円', '半額', '2', '-120円', '合計 480円' ]
    ownership = nil
    allow(Analysis::ReceiptFactOwnershipResolver).to receive(:call).and_wrap_original do |method, **arguments|
      ownership = method.call(**arguments)
    end

    [ { source_span_start: nil }, { source_span_start: '0', source_span_end: 5 }, { source_span_start: 0, source_span_end: 4 } ].each do |span|
      result = Analysis.build_receipt_params(
        ocr_result: adjustment_ocr_result(lines: lines),
        ai_result: {
          receipt_adjustments_attributes: [
            { kind: 'other', label: '半額', amount: 120, sign: 'discount', source_line_index: 3 }.merge(span)
          ]
        }
      )

      expect(ownership.facts.sole.fact_type).to eq(:unknown_adjustment)
      expect(result[:receipt_adjustments_attributes]).to contain_exactly(include(kind: 'other', amount: 120, needs_review: true))
      expect(result[:receipt_adjustments_attributes].sole.keys).not_to include(:source_span_start, :source_span_end)
    end
  end

  it 'source textに加えた別ownerの主張から2行先の金額を新たに借用しない' do
    [ 'クーポン 半額', 'キャッシュレス還元 半額' ].each do |source|
      result = Analysis.build_receipt_params(
        ocr_result: adjustment_ocr_result(lines: [ '小計 600円', '半額', '2', '-120円', '合計 480円' ]),
        ai_result: {
          receipt_adjustments_attributes: [
            { kind: 'other', amount: 120, sign: 'discount', source_line_index: 1, source_text: source }
          ]
        }
      )

      expect(result[:receipt_adjustments_attributes]).to be_empty
    end
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
