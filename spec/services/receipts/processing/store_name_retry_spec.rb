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
end
