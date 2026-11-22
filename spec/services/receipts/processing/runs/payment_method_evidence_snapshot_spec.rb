require 'rails_helper'

RSpec.describe Receipts::Processing::Runs::SnapshotBuilder do
  let(:lines) { [ '売上', 'id', '合計 864円' ] }
  let(:evidence) do
    {
      source_kind: 'azure_same_row', method: 'e_money', page_index: 0,
      label_line_index: 0, method_line_index: 1,
      label_path: 'pages[0].lines[0]', method_path: 'pages[0].lines[1]',
      label_span: { offset: 0, length: 2 }, method_span: { offset: 3, length: 2 },
      string_index_type: 'textElements'
    }
  end
  let(:ocr_result) do
    {
      success: true, lines: lines,
      candidates: { country_region: 'JPN', total_amount: 864, payment_method_text: 'id',
                    payment_method_evidence: evidence, items: [], payments: [] }
    }
  end

  def restored(snapshot)
    Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(snapshot)
  end

  it '決済方式と構造的な根拠だけを切り詰めず往復する' do
    snapshot = described_class.ocr_result_snapshot(ocr_result)
    rehydrated = restored(snapshot)

    aggregate_failures do
      expect(snapshot.dig('candidates', 'payment_method_evidence')).to eq(evidence.deep_stringify_keys)
      expect(rehydrated.fetch(:candidates).fetch('payment_method_evidence')).to eq(evidence.deep_stringify_keys)
      expect(described_class.ocr_result_snapshot(rehydrated)).to eq(snapshot)
      expect(snapshot.dig('candidates', 'payments')).to eq([])
    end
  end

  it 'directと再読込で同じ分類を保ち支払明細や金額を追加しない' do
    ai_result = { receipt_attributes: { payment_method: 'credit_card' } }
    direct = Analysis.build_receipt_params(ocr_result: ocr_result, ai_result: ai_result)
    reloaded = Analysis.build_receipt_params(ocr_result: restored(described_class.ocr_result_snapshot(ocr_result)), ai_result: ai_result)

    [ direct, reloaded ].each do |result|
      expect(result[:receipt_attributes]).to include(payment_method: 'e_money', total_amount: 864)
      expect(result[:receipt_payments_attributes]).to eq([])
      expect(result[:receipt_items_attributes]).to eq([])
    end
  end

  it '旧snapshotにない根拠を行の近接から生成しない' do
    ocr_result[:candidates].delete(:payment_method_evidence)
    snapshot = described_class.ocr_result_snapshot(ocr_result)

    expect(snapshot.fetch('candidates')).not_to have_key('payment_method_evidence')
    expect(restored(snapshot).fetch(:candidates)).not_to have_key('payment_method_evidence')
  end

  it '候補コンテナが不正でも決済根拠を作らず例外にしない' do
    ocr_result[:candidates] = []

    expect(described_class.ocr_result_snapshot(ocr_result).fetch('candidates')).not_to have_key('payment_method_evidence')
  end

  it '未知fieldを含む根拠は全体を拒否し本文を保存しない' do
    evidence[:content] = 'untrusted raw content'
    snapshot = described_class.ocr_result_snapshot(ocr_result)

    expect(snapshot.fetch('candidates')).not_to have_key('payment_method_evidence')
    expect(snapshot.to_json).not_to include('untrusted raw content')
  end

  it 'snapshot上限による行の欠落後に根拠を保持しない' do
    allow(described_class).to receive(:snapshot_ocr_lines_max).and_return(1)
    snapshot = described_class.ocr_result_snapshot(ocr_result)

    expect(snapshot.fetch('candidates')).not_to have_key('payment_method_evidence')
    expect(snapshot.dig('truncated', 'lines')).to be(true)
  end

  it '文字列の切り詰めや空行除去で行の同一性を失ったら根拠を落とす' do
    lines.unshift(nil)
    evidence[:label_line_index] = 1
    evidence[:method_line_index] = 2
    snapshot = described_class.ocr_result_snapshot(ocr_result)

    expect(snapshot.fetch('candidates')).not_to have_key('payment_method_evidence')
  end

  %w[lines items payments].each do |key|
    it "#{key}が切り詰められた保存データは根拠として復元しない" do
      snapshot = described_class.ocr_result_snapshot(ocr_result)
      snapshot.fetch('truncated')[key] = true

      expect(restored(snapshot).fetch(:candidates)).not_to have_key('payment_method_evidence')
      expect(described_class.ocr_result_snapshot(restored(snapshot)).fetch('candidates')).not_to have_key('payment_method_evidence')
    end
  end

  it '改変した方式や不明なschemaの根拠を復元しない' do
    snapshot = described_class.ocr_result_snapshot(ocr_result)
    snapshot.fetch('candidates')['payment_method_evidence'] = evidence.deep_stringify_keys.merge('method' => 'credit_card')

    expect(restored(snapshot).fetch(:candidates)).not_to have_key('payment_method_evidence')

    snapshot.fetch('candidates')['payment_method_evidence'] = evidence.deep_stringify_keys
    snapshot['schema_version'] = 'unknown'

    expect(restored(snapshot).fetch(:candidates)).not_to have_key('payment_method_evidence')
  end

  it '不正な完全性flagはfalseへ読み替えて根拠を保持しない' do
    snapshot = described_class.ocr_result_snapshot(ocr_result)
    snapshot.fetch('truncated')['payments'] = 'false'

    expect(restored(snapshot).fetch(:candidates)).not_to have_key('payment_method_evidence')
  end
end
