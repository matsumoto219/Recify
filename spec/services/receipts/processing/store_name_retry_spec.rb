require 'rails_helper'

RSpec.describe '店舗名選択のsnapshot往復' do
  let(:builder) { Receipts::Processing::Runs::SnapshotBuilder }
  let(:rehydrator) { Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator }
  let(:ocr_result) do
    {
      success: true,
      lines: [ 'samplemart', '領収書' ],
      case_preserved_lines: [ 'SampleMart', '領収書' ],
      candidates: {
        store_name: 'samplemart',
        store_name_evidence: {
          schema_version: 'store_name_evidence_v1', truncated: false, invalid: false,
          candidates: [
            {
              candidate_id: 'line_0', source: 'line', source_path: 'lines[0]',
              line_index: 0, text: 'SampleMart', span_state: 'missing'
            }
          ]
        }
      }
    }
  end

  it 'AI retryのOCR再構築とfinalize retryで同じ候補集合と選択を維持する' do
    options = Analysis.store_name_options(ocr_result: ocr_result)
    selection = Analysis.store_name_selection(
      { decision: 'select', option_id: options[:options].first[:option_id] }, options: options
    )
    ai_result = { success: true, meta: { store_name_selection: selection } }
    ocr_snapshot = builder.ocr_result_snapshot(ocr_result)
    ai_snapshot = builder.ai_normalized_result_snapshot(ai_result)
    restored_ocr = rehydrator.ocr(JSON.parse(ocr_snapshot.to_json))
    restored_ai = rehydrator.ai(JSON.parse(ai_snapshot.to_json))

    expect(restored_ai.dig(:meta, 'store_name_selection', 'options_schema_version')).to eq('store_name_options_v1')
    expect(Analysis.store_name_options(ocr_result: restored_ocr)).to eq(options)
    expect(Analysis.build_receipt_params(ocr_result: restored_ocr, ai_result: restored_ai)).to include(
      store_name_resolution: include(state: 'confirmed', option_id: options[:options].first[:option_id])
    )
    expect(Analysis.build_receipt_params(ocr_result: restored_ocr, ai_result: restored_ai)
      .dig(:receipt_attributes, :store_name)).to eq('SampleMart')
  end

  it '候補集合変更後に古いAI選択を別の店名へ読み替えない' do
    options = Analysis.store_name_options(ocr_result: ocr_result)
    selection = Analysis.store_name_selection(
      { decision: 'select', option_id: options[:options].first[:option_id] }, options: options
    )
    ocr_result[:candidates][:store_name_evidence][:candidates].first[:text] = 'ChangedMart'
    changed_options = Analysis.store_name_options(ocr_result: ocr_result)

    expect(Analysis.store_name_selection(selection, options: changed_options)).to include(decision: 'invalid')
  end

  it '連続page行の合成optionもsnapshot往復後に同じ出典と選択名で解決する' do
    lines = [ 'サンプル公園', '駐車場' ]
    ocr_result[:lines] = lines
    ocr_result[:case_preserved_lines] = lines
    ocr_result[:candidates][:store_name] = 'サンプル公園'
    ocr_result[:candidates][:store_name_evidence][:candidates] = lines.each_with_index.map do |text, index|
      {
        candidate_id: "page_0_line_#{index}", source: 'line', source_path: "pages[0].lines[#{index}]",
        line_index: index, page_index: 0, provider_line_index: index, text: text,
        span_state: 'exact', span: { offset: index * 20, length: text.length }, string_index_type: 'textElements'
      }
    end
    options = Analysis.store_name_options(ocr_result: ocr_result)
    option = options[:options].find { |candidate| candidate[:value] == 'サンプル公園駐車場' }
    selection = Analysis.store_name_selection({ decision: 'select', option_id: option[:option_id] }, options: options)
    restored_ocr = rehydrator.ocr(JSON.parse(builder.ocr_result_snapshot(ocr_result).to_json))
    restored_ai = rehydrator.ai(JSON.parse(builder.ai_normalized_result_snapshot(success: true, meta: { store_name_selection: selection }).to_json))

    result = Analysis.build_receipt_params(ocr_result: restored_ocr, ai_result: restored_ai)

    expect(Analysis.store_name_options(ocr_result: restored_ocr)).to eq(options)
    expect(result[:store_name_resolution]).to include(state: 'confirmed', option_id: option[:option_id])
    expect(result.dig(:receipt_attributes, :store_name)).to eq('サンプル公園駐車場')

    historical_selection = {
      decision: 'select', option_id: 'store_option_2e0f56e091d035f87249ce0869b78013',
      options_checksum: '9e1d5d8f9272a4c7b55a59aaa050ebe7b75fcf08ca9bc1c6ea0036626f06c8e4'
    }
    historical_result = Analysis.build_receipt_params(
      ocr_result: restored_ocr, ai_result: { success: true, meta: { store_name_selection: historical_selection } }
    )

    expect(historical_result[:store_name_resolution]).to include(state: 'confirmed', option_id: historical_selection[:option_id])
    expect(historical_result.dig(:receipt_attributes, :store_name)).to eq('サンプル公園駐車場')
  end

  it '汎用文字列上限でOCR行が短縮されても検証済み店舗名と選択を維持する' do
    name = ('サンプル' * 12) + '商店'
    ocr_result[:lines] = [ name ]
    ocr_result[:case_preserved_lines] = [ name ]
    ocr_result[:candidates][:store_name] = name
    ocr_result[:candidates][:store_name_evidence][:candidates].first[:text] = name
    options = Analysis.store_name_options(ocr_result: ocr_result)
    selection = Analysis.store_name_selection(
      { decision: 'select', option_id: options[:options].first[:option_id] }, options: options
    )
    allow(builder).to receive(:snapshot_string_max_bytes).and_return(100)

    snapshot = builder.ocr_result_snapshot(ocr_result)
    restored_ocr = rehydrator.ocr(JSON.parse(snapshot.to_json))
    restored_ai = rehydrator.ai(builder.ai_normalized_result_snapshot(success: true, meta: { store_name_selection: selection }))

    expect(snapshot.fetch('lines').first.bytesize).to be <= 100
    expect(Analysis.store_name_options(ocr_result: restored_ocr)).to eq(options)
    expect(Analysis.build_receipt_params(ocr_result: restored_ocr, ai_result: restored_ai)
      .dig(:receipt_attributes, :store_name)).to eq(name)
  end

  %w[store_name_options_v1 store_name_options_v2].each do |version|
    it "#{version}で店舗名欠損をsnapshot往復後も維持し、案内文で埋めない" do
      lines = [ '領収書', '合計100円', '詳しくは係員まで' ]
      ocr_result[:lines] = lines
      ocr_result[:case_preserved_lines] = lines
      ocr_result[:candidates].merge!(store_name: nil, total_amount: 100, subtotal_amount: 100, tax_amount: 0)
      ocr_result[:candidates][:store_name_evidence][:candidates] = [
        { candidate_id: 'line_2', source: 'line', source_path: 'lines[2]', line_index: 2, text: lines.last, span_state: 'missing' }
      ]
      options = Analysis.store_name_options(ocr_result: ocr_result, version: version)
      selection = Analysis.store_name_selection({ decision: 'reject', relations: [] }, options: options)
      ai_result = {
        success: true, needs_review: true, review_reasons: [ 'store_name_missing' ],
        receipt_attributes: {}, meta: { store_name_selection: selection }
      }
      restored_ocr = rehydrator.ocr(JSON.parse(builder.ocr_result_snapshot(ocr_result).to_json))
      restored_ai = rehydrator.ai(JSON.parse(builder.ai_normalized_result_snapshot(ai_result).to_json))

      result = Analysis.build_receipt_params(ocr_result: restored_ocr, ai_result: restored_ai)

      aggregate_failures do
        expect(Analysis.store_name_options(ocr_result: restored_ocr, version: version)).to eq(options)
        expect(restored_ai.dig(:meta, 'store_name_selection')).to eq(selection.deep_stringify_keys)
        expect(result[:store_name_resolution]).to eq(state: 'missing', option_id: nil, reason_codes: [ 'store_name_missing' ])
        expect(result[:review_reasons]).to include('store_name_missing')
        expect(result[:review_reasons]).not_to include('store_name_uncertain')
        expect(result[:receipt_attributes].slice(:store_name, :subtotal_amount, :tax_amount, :total_amount)).to eq(
          store_name: nil, subtotal_amount: 100, tax_amount: 0, total_amount: 100
        )
      end
    end
  end

  context '成分間の関係を含むv2選択' do
    let(:ocr_result) do
      lines = [ 'みどり食堂', 'ひだまりテラス南' ]
      {
        success: true, lines: lines, case_preserved_lines: lines,
        candidates: {
          store_name: lines.first, total_amount: 540, subtotal_amount: 500, tax_amount: 40, tax_rate: 8,
          purchased_at_text: '2026/05/23 10:00', payment_method_text: '現金',
          items: [ { raw_text: 'サンプル品', price: 540, quantity: 1, quantity_unit_code: 'each', line_total: 540, tax_rate: 8 } ],
          payments: [ { method: 'Cash', amount: 540 } ],
          tax_details: [ { rate: 8, net_amount: 500, amount: 40 } ],
          store_name_evidence: {
            schema_version: 'store_name_evidence_v1', truncated: false, invalid: false,
            candidates: lines.each_with_index.map do |text, index|
              {
                candidate_id: "page_0_line_#{index}", source: 'line', source_path: "pages[0].lines[#{index}]",
                line_index: index, page_index: 0, provider_line_index: index, text: text,
                span_state: 'exact', span: { offset: index * 30, length: text.length }, string_index_type: 'textElements'
              }
            end
          }
        }
      }
    end
    let(:options) { Analysis.store_name_options(ocr_result: ocr_result, version: 'store_name_options_v2') }
    let(:full_option) { options[:options].find { |option| option[:value] == 'みどり食堂 ひだまりテラス南' } }
    let(:relation) { options[:relations].sole }
    let(:selection) do
      Analysis.store_name_selection(
        {
          decision: 'select', option_id: full_option[:option_id],
          relations: [ { relation_id: relation[:relation_id], decision: 'store_location' } ]
        }, options: options
      )
    end

    def restore_selection(value)
      rehydrator.ai(JSON.parse(builder.ai_normalized_result_snapshot(success: true, meta: { store_name_selection: value }).to_json))
    end

    it '保存と再構築で関係回答・表示空白・金額を保持し、正しいAI選択を要確認にしない' do
      restored_ocr = rehydrator.ocr(JSON.parse(builder.ocr_result_snapshot(ocr_result).to_json))
      restored_ai = restore_selection(selection)
      result = Analysis.build_receipt_params(ocr_result: restored_ocr, ai_result: restored_ai)
      baseline = Analysis.build_receipt_params(ocr_result: restored_ocr, ai_result: nil)

      expect(restored_ai.dig(:meta, 'store_name_selection')).to eq(selection.deep_stringify_keys)
      expect(result[:store_name_resolution]).to include(state: 'confirmed', option_id: full_option[:option_id], reason_codes: [])
      expect(result.dig(:receipt_attributes, :store_name)).to eq('みどり食堂 ひだまりテラス南')
      expect(result[:receipt_attributes].except(:store_name)).to eq(baseline[:receipt_attributes].except(:store_name))
      expect(result[:receipt_items_attributes]).to eq(baseline[:receipt_items_attributes])
    end

    it '一つの名称でも区切りを持つ表示候補を保存往復と金額計算後に保持する' do
      chosen = Analysis.store_name_selection(
        {
          decision: 'select', option_id: full_option[:option_id],
          relations: [ { relation_id: relation[:relation_id], decision: 'same_name' } ]
        }, options: options
      )
      restored_ocr = rehydrator.ocr(JSON.parse(builder.ocr_result_snapshot(ocr_result).to_json))
      restored_ai = restore_selection(chosen)
      result = Analysis.build_receipt_params(ocr_result: restored_ocr, ai_result: restored_ai)
      baseline = Analysis.build_receipt_params(ocr_result: restored_ocr, ai_result: nil)

      expect(chosen).to include(decision: 'select', option_id: full_option[:option_id])
      expect(restored_ai.dig(:meta, 'store_name_selection')).to eq(chosen.deep_stringify_keys)
      expect(result[:store_name_resolution]).to include(state: 'confirmed', reason_codes: [])
      expect(result.dig(:receipt_attributes, :store_name)).to eq('みどり食堂 ひだまりテラス南')
      expect(result[:receipt_attributes].except(:store_name)).to eq(baseline[:receipt_attributes].except(:store_name))
      expect(result[:receipt_items_attributes]).to eq(baseline[:receipt_items_attributes])
    end

    [ false, true ].each do |inconsistent|
      it "async Finalizeと再実行で店舗名・金額・確認状態を維持する（関係矛盾: #{inconsistent}）" do
        receipt = create(:receipt, :processing, :with_image)
        run = create(:receipt_analysis_run, receipt: receipt)
        chosen = selection
        if inconsistent
          partial = options[:options].find { |option| option[:value] == 'みどり食堂' }
          chosen = selection.merge(option_id: partial[:option_id])
        end
        ai_result = {
          success: true, needs_review: false, review_reasons: [],
          receipt_attributes: { purchased_at: Time.zone.parse('2026-05-23 10:00'), payment_method: 'cash' },
          receipt_items_attributes: [ { index: 0, category: 'food', needs_review: false } ],
          meta: { store_name_selection: chosen }
        }
        decision = Receipts::Processing::Contracts::FinalizeDecision.new(
          finalize_strategy: :ai_success, receipt_attributes: {}, metadata: {}
        )
        Receipts::Processing.record_ocr_snapshot(run, ocr_result)
        Receipts::Processing.record_ai_normalized_result(run, ai_result)
        Receipts::Processing.record_finalize_decision(run, decision)

        result = Receipts::Processing.run_finalize(run)
        receipt.reload

        expect(result.next_step).to eq(:done)
        expect(receipt.status).to eq(inconsistent ? 'review_needed' : 'completed')
        expect(receipt.review_reasons).to eq(inconsistent ? [ 'store_name_uncertain' ] : [])
        expect(receipt.store_name).to eq(inconsistent ? 'みどり食堂' : 'みどり食堂 ひだまりテラス南')
        expect(receipt.attributes.slice('subtotal_amount', 'tax_amount', 'total_amount')).to eq(
          'subtotal_amount' => 500, 'tax_amount' => 40, 'total_amount' => 540
        )
        expect(receipt.receipt_items.pluck(:price, :quantity, :line_total)).to eq([ [ 540, 1, 540 ] ])
        saved = receipt.attributes
        saved_items = receipt.receipt_items.order(:id).map(&:attributes)

        expect(Receipts::Processing.run_finalize(run).next_step).to eq(:skipped)
        expect(receipt.reload.attributes).to eq(saved)
        expect(receipt.receipt_items.order(:id).map(&:attributes)).to eq(saved_items)
      end
    end

    it '施設名を認めながらブランドだけ選んだ回答は保存往復後もconfirmedにしない' do
      partial = options[:options].find { |option| option[:value] == 'みどり食堂' }
      inconsistent = selection.merge(option_id: partial[:option_id])
      result = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: restore_selection(inconsistent))

      expect(result[:store_name_resolution]).to include(state: 'uncertain', reason_codes: [ 'store_name_uncertain' ])
      expect(result.dig(:receipt_attributes, :store_name)).to eq(
        Analysis.build_receipt_params(ocr_result: ocr_result).dig(:receipt_attributes, :store_name)
      )
    end

    it '候補が一つでもv2選択の検証失敗をOCR確定へすり替えない' do
      ocr_result[:lines] = [ 'みどり食堂' ]
      ocr_result[:case_preserved_lines] = ocr_result[:lines]
      ocr_result[:candidates][:store_name_evidence][:candidates].pop
      current = Analysis.store_name_options(ocr_result: ocr_result, version: 'store_name_options_v2')
      invalid = {
        decision: 'select', option_id: current[:options].sole[:option_id], relations: [],
        options_schema_version: 'store_name_options_v2', options_checksum: '0' * 64
      }
      result = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: restore_selection(invalid))

      expect(result[:store_name_resolution]).to include(state: 'uncertain', reason_codes: [ 'store_name_uncertain' ])
      expect(result.dig(:receipt_attributes, :store_name)).to eq('みどり食堂')
    end

    it '関係回答の欠損とchecksum不一致をfallbackで確定済みに変えない' do
      [ selection.except(:relations), selection.merge(options_checksum: '0' * 64) ].each do |invalid|
        result = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: restore_selection(invalid))[:store_name_resolution]

        expect(result).to include(state: 'uncertain', reason_codes: [ 'store_name_uncertain' ])
      end
    end
  end
end
