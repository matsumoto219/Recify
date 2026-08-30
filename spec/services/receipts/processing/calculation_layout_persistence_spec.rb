require 'rails_helper'

RSpec.describe 'Calculation layout persistence' do
  def calculation_layout_response(text_lines)
    offset = 0
    words = []
    lines = text_lines.map.with_index do |text, index|
      top = 20 + index * 24
      text.to_enum(:scan, /\S+/).each do
        match = Regexp.last_match
        left = 20 + match.begin(0) * 10
        right = left + match[0].length * 10
        words << {
          'content' => match[0],
          'span' => { 'offset' => offset + match.begin(0), 'length' => match[0].length },
          'polygon' => [ left, top, right, top, right, top + 16, left, top + 16 ]
        }
      end
      line = {
        'content' => text,
        'spans' => [ { 'offset' => offset, 'length' => text.length } ],
        'polygon' => [ 20, top, 20 + text.length * 10, top, 20 + text.length * 10, top + 16, 20, top + 16 ]
      }
      offset += text.length + 1
      line
    end
    {
      'analyzeResult' => {
        'modelId' => 'prebuilt-receipt',
        'apiVersion' => '2024-11-30',
        'stringIndexType' => 'textElements',
        'content' => text_lines.join("\n"),
        'pages' => [
          {
            'pageNumber' => 1,
            'unit' => 'pixel',
            'width' => 600,
            'height' => 40 + lines.size * 24,
            'lines' => lines,
            'words' => words
          }
        ],
        'documents' => [ { 'fields' => {} } ]
      }
    }
  end

  def prepare_calculation_layout_run(text_lines, setting_enabled: true)
    create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(setting_enabled)
    )
    ocr_result = Ocr::ResponseParser.new(response: calculation_layout_response(text_lines), provider: :fixture).call
    receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    run = Receipts::Processing.start(receipt:, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(run, ocr_result)
    decision = Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: 'ocr_only',
      error_code: nil,
      error_message: nil,
      receipt_attributes: {},
      ocr_result: nil,
      ai_result: nil,
      metadata: {}
    )
    Receipts::Processing.record_finalize_decision(run, decision)
    run.reload
  end

  def mixed_calculation_lines
    [
      'レシート',
      '検証個数品(税込1%)', '単価 @100円', '数量 2個', '明細計 200円',
      '検証量売粉(税込27%)', '税込 300円/100g', '計量 250g', '明細計 750円',
      '検証量売液(税込75%)', '税込 120円/500ml', '計量 1.5L', '明細計 360円',
      '検証固定作業(税込31%)', '明細計 50円',
      '合計 1360円'
    ]
  end

  it 'Items欠損でもcount・explicit・0円・欠損明細を混同せず保存する' do
    run = prepare_calculation_layout_run([
      'レシート',
      '検証品甲(税込27%)', '単価 @100円', '数量 2個', '明細計 200円',
      '検証品乙(税込27%)', '明細計 90円',
      '検証品丙(税込27%)', '明細計 0円',
      '検証品丁(税込27%)', '数量 2個',
      '合計 290円'
    ])
    result = Receipts::Processing.run_finalize(run)
    items = run.receipt.reload.receipt_items.order(:position_index)

    aggregate_failures do
      expect(result.next_step).to eq(:done)
      expect(items.size).to eq(4)
      expect(items.pluck(:pricing_source_kind)).to eq([ 'count_unit_price', 'explicit_line_total', 'explicit_line_total', nil ])
      expect(items.pluck(:line_total)).to eq([ 200, 90, 0, 0 ])
      expect(items.last.review_reasons).to include('item_pricing_mode_uncertain')
      expect(run.ocr_result_snapshot.dig('adoption_proposals', 'item_calculation_modes').size).to eq(3)
    end
  end

  it '同一Receiptのcount・複数reference・explicitを全件保持しretryで重複保存しない' do
    run = prepare_calculation_layout_run(mixed_calculation_lines)
    first_result = Receipts::Processing.run_finalize(run)
    receipt = run.receipt.reload
    items = receipt.receipt_items.order(:position_index)
    sources = items.map(&:attributes)
    second_result = Receipts::Processing.run_finalize(run.reload)

    aggregate_failures do
      expect(first_result.next_step).to eq(:done)
      expect(second_result.next_step).to eq(:skipped)
      expect(items.pluck(:pricing_source_kind)).to eq(%w[count_unit_price reference_quantity_price reference_quantity_price explicit_line_total])
      expect(items.pluck(:line_total)).to eq([ 200, 750, 360, 50 ])
      expect(items[1..2].map(&:reference_quantity_unit_code)).to eq(%w[gram milliliter])
      expect(items[1..2].map(&:quantity_unit_code)).to eq(%w[gram liter])
      expect(receipt.total_amount).to eq(1360)
      expect(receipt.reload.receipt_items.order(:position_index).map(&:attributes)).to eq(sources)
    end
  end

  it 'setting OFFでも全明細と候補を保持しreference authorityだけを書かない' do
    run = prepare_calculation_layout_run(mixed_calculation_lines, setting_enabled: false)
    Receipts::Processing.run_finalize(run)
    items = run.receipt.reload.receipt_items.order(:position_index)

    aggregate_failures do
      expect(items.size).to eq(4)
      expect(items.pluck(:pricing_source_kind)).to eq([ 'count_unit_price', nil, nil, 'explicit_line_total' ])
      expect(items.pluck(:line_total)).to eq([ 200, 750, 360, 50 ])
      expect(items[1..2].map(&:reference_price_amount)).to eq([ nil, nil ])
      expect(run.ocr_result_snapshot.dig('adoption_proposals', 'item_calculation_modes').size).to eq(4)
    end
  end
end
