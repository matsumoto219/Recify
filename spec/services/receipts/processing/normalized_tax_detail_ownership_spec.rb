require 'rails_helper'

RSpec.describe '正規化済み税対象額のpipeline ownership' do
  def parsed_tax_receipt(total: 109, tax: 1, rate: 1, tax_detail_shape: :summary_field)
    lines = [ '検証商品', "消費税 ¥#{tax}", "合計 ¥#{total}", "#{rate}%対象計 ¥#{total}", "(内税額 ¥#{tax})" ]
    raw = {
      'analyzeResult' => {
        'content' => lines.join("\n"),
        'pages' => [ { 'lines' => lines.map { |line| { 'content' => line } } } ],
        'documents' => [
          {
            'fields' => {
              'Total' => { 'valueCurrency' => { 'amount' => total } },
              'Subtotal' => { 'valueCurrency' => { 'amount' => total - tax } },
              'TotalTax' => { 'valueCurrency' => { 'amount' => tax } },
              'Items' => {
                'valueArray' => [
                  {
                    'valueObject' => {
                      'Description' => { 'valueString' => '検証商品' },
                      'TotalPrice' => { 'valueCurrency' => { 'amount' => total } }
                    }
                  }
                ]
              }
            }
          }
        ]
      }
    }
    fields = raw.dig('analyzeResult', 'documents', 0, 'fields')
    if tax_detail_shape == :split_tax_only
      fields.delete('TotalTax')
      fields['TaxDetails'] = {
        'valueArray' => %w[税 内税額].map do |description|
          {
            'valueObject' => {
              'Amount' => { 'valueCurrency' => { 'amount' => tax } },
              'Description' => { 'valueString' => description }
            }
          }
        end
      }
    elsif tax_detail_shape == :structured_rate
      fields['TaxDetails'] = {
        'valueArray' => [
          {
            'valueObject' => {
              'Rate' => { 'valueNumber' => BigDecimal(rate.to_s) / 100 },
              'Amount' => { 'valueCurrency' => { 'amount' => tax } }
            }
          }
        ]
      }
    end

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def snapshot_round_trip(result)
    snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
    Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(JSON.parse(JSON.generate(snapshot)))
  end

  it 'line evidenceのcanonical netをsnapshotとBuildParams hintへ保持する' do
    parsed = parsed_tax_receipt
    expect(parsed.dig(:candidates, :tax_detail_amount_basis)).to eq('net')
    rehydrated = snapshot_round_trip(parsed)
    expect(rehydrated.dig(:candidates, 'tax_detail_amount_basis')).to eq('net')
    params = Analysis.build_receipt_params(ocr_result: rehydrated)

    expect(params[:amount_hints]).to include(tax_detail_amount_basis: 'net')
    expect(params[:receipt_attributes]).not_to have_key(:tax_detail_amount_basis)
    params[:receipt_tax_details_attributes].each do |detail|
      expect(detail).not_to have_key(:tax_detail_amount_basis)
    end
  end

  it '切り詰め済み税明細に全体net basisを再利用しない' do
    snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(parsed_tax_receipt)
    snapshot['truncated']['tax_details'] = true
    snapshot['candidates']['tax_detail_amount_basis'] = 'net'
    rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(snapshot)

    expect(rehydrated[:candidates]).not_to have_key('tax_detail_amount_basis')
    expect(snapshot_round_trip(rehydrated)[:candidates]).not_to have_key('tax_detail_amount_basis')
  end

  it 'actual countが保存行数と異なる場合はnet basisを破棄する' do
    snapshot = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(parsed_tax_receipt)
    snapshot['candidate_counts']['tax_details']['actual_count'] = 2
    snapshot['candidates']['tax_detail_amount_basis'] = 'net'

    result = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(snapshot)
    expect(result[:candidates]).not_to have_key('tax_detail_amount_basis')
  end

  it 'snapshotの未知basisを通さない' do
    parsed = parsed_tax_receipt
    parsed[:candidates][:tax_detail_amount_basis] = 'gross'

    expect(snapshot_round_trip(parsed)[:candidates]).not_to have_key('tax_detail_amount_basis')
  end

  it '型の不正なcount metadataからnet basisを引き継がない' do
    parsed = parsed_tax_receipt
    parsed[:candidate_counts] = { tax_details: 'invalid' }

    expect(Analysis.build_receipt_params(ocr_result: parsed)[:amount_hints]).not_to have_key(:tax_detail_amount_basis)
  end

  [ nil, false, [], {} ].each do |counts|
    it "空または不正な税明細count #{counts.inspect}からnet hintを作らない" do
      parsed = parsed_tax_receipt
      parsed[:candidate_counts] = { tax_details: counts }

      expect(Analysis.build_receipt_params(ocr_result: parsed)[:amount_hints]).not_to have_key(:tax_detail_amount_basis)
    end
  end

  %i[split_tax_only structured_rate].each do |shape|
    it "#{shape}からBuildParamsで初めて正規化したnetもownershipを保持する" do
      parsed = parsed_tax_receipt(tax_detail_shape: shape)
      expect(parsed.dig(:candidates, :tax_detail_amount_basis)).to be_nil
      params = Analysis.build_receipt_params(ocr_result: snapshot_round_trip(parsed))

      expect(params[:receipt_tax_details_attributes].first[:net_amount]).to eq(108)
      expect(params[:amount_hints]).to include(tax_detail_amount_basis: 'net')
    end
  end

  %i[candidate_counts truncated].each do |key|
    it "#{key}自体の型不正はraiseせずnet hintを拒否する" do
      parsed = parsed_tax_receipt
      parsed[key] = 'invalid'

      expect(Analysis.build_receipt_params(ocr_result: parsed)[:amount_hints]).not_to have_key(:tax_detail_amount_basis)
    end
  end

  it '最終tax rowsがOCRで確定したsourceと異なる場合はhintを渡さない' do
    parsed = parsed_tax_receipt
    allow(Analysis::ReceiptFactOwnershipResolver).to receive(:call).and_wrap_original do |original, **arguments|
      result = original.call(**arguments)
      result.tax_details.first[:net_amount] = 107
      result
    end

    params = Analysis.build_receipt_params(ocr_result: parsed)

    expect(params[:receipt_tax_details_attributes].first[:net_amount]).to eq(107)
    expect(params[:amount_hints]).not_to have_key(:tax_detail_amount_basis)
  end

  it 'providerのstructured税詳細だけからnet ownershipを推測しない' do
    raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)
    parsed = Ocr::ResponseParser.new(response: raw, provider: :fixture).call

    expect(parsed.dig(:candidates, :tax_detail_amount_basis)).to be_nil
  end

  [
    [ 109, 1, 1, :summary_field ],
    [ 108, 22, 27, :summary_field ],
    [ 109, 1, 1, :split_tax_only ],
    [ 108, 22, 27, :structured_rate ]
  ].each do |total, tax, rate, shape|
    it "#{rate}%の#{shape}税込印字をFinalize再実行と保存後編集でも二重控除しない" do
      receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
      run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
      Receipts::Processing.record_ocr_snapshot(run, parsed_tax_receipt(total: total, tax: tax, rate: rate, tax_detail_shape: shape))
      Receipts::Processing.record_finalize_decision(
        run,
        Receipts::Processing::Contracts::FinalizeDecision.new(
          finalize_strategy: 'ocr_only',
          error_code: nil,
          error_message: nil,
          receipt_attributes: {},
          ocr_result: nil,
          ai_result: nil,
          metadata: {}
        )
      )

      Receipts::Processing.run_finalize(run.reload)
      receipt.reload
      expect(receipt).to have_attributes(total_amount: total, subtotal_amount: total - tax, tax_amount: tax)
      item_ids = receipt.receipt_items.pluck(:id)
      Receipts::Processing.run_finalize(run.reload)
      expect(receipt.reload.receipt_items.pluck(:id)).to eq(item_ids)

      result = ReceiptAmountService.call(
        receipt: receipt.attributes.merge(receipt.amount_source_semantics_for_edit),
        receipt_items: receipt.receipt_items.map(&:attributes),
        receipt_tax_details: receipt.receipt_tax_details.map(&:attributes),
        context: :edit_save
      )
      expect(result[:resolved]).to include(subtotal: total - tax, tax: tax, total: total)
      attributes = Receipts::Editing.apply_amount_result!(
        receipt: receipt,
        attributes: {},
        amount_result: result,
        context: :edit_save,
        change_set: nil,
        tax_details_recalculated: false
      )
      saved = Receipts::Editing.update_manual(receipt: receipt, attributes: attributes, items_missing: false)
      expect(saved).to be_saved
      expect(receipt.reload).to have_attributes(total_amount: total, subtotal_amount: total - tax, tax_amount: tax)
    end
  end
end
