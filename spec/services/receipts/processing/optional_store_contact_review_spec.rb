require 'rails_helper'

RSpec.describe 'Optional store contact review' do
  it '任意の連絡先だけが根拠なく欠損していても、日時や支払の要確認と混同しない' do
    receipt = create(:receipt, :processing, :with_image)
    run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(
      run,
      {
        success: true,
        raw_text: "検証店\n検証品A 300\n合計 300",
        lines: [ '検証店', '検証品A 300', '合計 300' ],
        candidates: {
          store_name: '検証店', total_amount: 300, country_region: 'JPN',
          items: [ { raw_text: '検証品A', price: 300, quantity: 1, line_total: 300, confidence: 0.95 } ]
        }
      }
    )
    Receipts::Processing.record_ai_normalized_result(
      run,
      {
        success: true, needs_review: true,
        review_reasons: %w[store_address_missing store_phone_number_missing],
        receipt_attributes: {},
        receipt_items_attributes: [ { index: 0, category: 'daily_goods', needs_review: false } ]
      }
    )
    Receipts::Processing.record_finalize_decision(
      run,
      Receipts::Processing::Contracts::FinalizeDecision.new(
        finalize_strategy: 'ai_success', receipt_attributes: {}, metadata: {}
      )
    )

    result = Receipts::Processing.run_finalize(run.reload)

    aggregate_failures do
      expect(result.next_step).to eq(:done)
      expect(receipt.reload).to have_attributes(status: 'review_needed', total_amount: 300)
      expect(receipt.review_reasons).to include('purchased_at_missing', 'payment_method_missing')
      expect(receipt.review_reasons).not_to include('store_address_missing', 'store_phone_number_missing')
      expect(receipt.store_address).to be_nil
      expect(receipt.store_phone_number).to be_nil
    end
  end

  describe 'missing reasonの根拠' do
    let(:step) do
      Receipts::Processing::Pipeline::FinalizeStep.new(receipt: build(:receipt), decision: nil)
    end
    let(:params) { { receipt_attributes: {} } }
    let(:ocr_result) { { candidates: {}, lines: [ '検証店', '検証品A 300', '合計 300' ] } }

    def resolve_missing_reason
      step.send(method_name, [ reason ], params, ocr_result)
    end

    shared_examples 'field-local missing review' do
      it '別の必須欄が未解消でも、OCRに根拠のない任意の欠損reasonだけを解除する' do
        expect(resolve_missing_reason).to be_empty
      end

      it 'OCR候補があるのに最終欄が欠損している場合はreasonを残す' do
        ocr_result[:candidates][field] = printed_value

        expect(resolve_missing_reason).to eq([ reason ])
      end

      it 'OCR行に印字の根拠があるのに最終欄が欠損している場合はreasonを残す' do
        ocr_result[:lines] << printed_value

        expect(resolve_missing_reason).to eq([ reason ])
      end

      it '既に当該欄が保存値を持つ場合は、別の必須欄の不備でmissingを残さない' do
        params[:receipt_attributes][field] = printed_value

        expect(resolve_missing_reason).to be_empty
      end

      it 'uncertain reasonはmissingとして解除しない' do
        uncertain = reason.sub('_missing', '_uncertain')

        expect(step.send(method_name, [ uncertain ], params, ocr_result)).to eq([ uncertain ])
      end

      it 'OCR行が省略されている場合は印字なしと決めつけない' do
        ocr_result[:truncated] = { lines: true }

        expect(resolve_missing_reason).to eq([ reason ])
      end

      [
        [ '完全性未記録', 'receipt_analysis_run_ocr_result_v1', {} ],
        [ '完全性の型違い', 'receipt_analysis_run_ocr_result_v1', { lines: 'false' } ],
        [ '未知version', 'unsupported', { lines: false } ],
        [ 'version未記録', nil, { lines: false } ]
      ].each do |label, version, truncated|
        it "#{label}の保存OCRを印字なしの根拠にしない" do
          restored = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(
            ocr_result.merge(schema_version: version, truncated: truncated)
          )

          expect(step.send(method_name, [ reason ], params, restored)).to eq([ reason ])
        end
      end

      it '既知versionで完全な保存OCRなら任意の欠損reasonを解除する' do
        restored = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(
          ocr_result.merge(schema_version: 'receipt_analysis_run_ocr_result_v1', truncated: { lines: false })
        )

        expect(step.send(method_name, [ reason ], params, restored)).to be_empty
      end

      it '差替えprofileの印字判定を使い、元の語彙を共有処理へ固定しない' do
        replacement = Struct.new(:signal_address_pattern, :signal_phone_pattern).new(/CONTACT-ADDRESS/, /CONTACT-PHONE/)
        allow(ReceiptAnalysisProfiles).to receive(:default).and_return(replacement)
        ocr_result[:lines] = [ printed_value ]

        expect(resolve_missing_reason).to be_empty
        ocr_result[:lines] = [ 'CONTACT-ADDRESS CONTACT-PHONE' ]
        expect(resolve_missing_reason).to eq([ reason ])
      end
    end

    context '住所' do
      let(:field) { :store_address }
      let(:reason) { 'store_address_missing' }
      let(:method_name) { :remove_resolved_store_address_missing_review_reason }
      let(:printed_value) { 'サンプル県検証市1-2-3' }

      include_examples 'field-local missing review'

      it 'OCRの構造化住所がある場合も印字なしと扱わない' do
        ocr_result[:candidates][:store_address_components] = { city: '検証市' }

        expect(resolve_missing_reason).to eq([ reason ])
      end
    end

    context '電話番号' do
      let(:field) { :store_phone_number }
      let(:reason) { 'store_phone_number_missing' }
      let(:method_name) { :remove_resolved_store_phone_number_missing_review_reason }
      let(:printed_value) { 'TEL 03-0000-0000' }

      include_examples 'field-local missing review'
    end
  end
end
