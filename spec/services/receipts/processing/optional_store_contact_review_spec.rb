require 'rails_helper'

RSpec.describe 'Optional store contact review' do
  def parsed_product_locality
    lines = [ '検証店', '001 検証市指定券 300', '合計 300' ]
    offset = 0
    provider_lines = lines.map do |line|
      entry = { 'content' => line, 'spans' => [ { 'offset' => offset, 'length' => line.length } ] }
      offset += line.length + 1
      entry
    end
    region = [ { 'pageNumber' => 1 } ]
    item = provider_lines[1].deep_dup.merge(
      'boundingRegions' => region,
      'valueObject' => {
        'Description' => {
          'valueString' => '検証市指定券', 'content' => '検証市指定券',
          'spans' => [ { 'offset' => 8, 'length' => 6 } ], 'boundingRegions' => region
        },
        'TotalPrice' => { 'valueCurrency' => { 'amount' => 300 } }
      }
    )
    response = {
      'analyzeResult' => {
        'modelId' => 'prebuilt-receipt',
        'apiVersion' => '2024-11-30',
        'stringIndexType' => 'textElements',
        'content' => lines.join("\n"),
        'pages' => [ { 'pageNumber' => 1, 'lines' => provider_lines } ],
        'documents' => [
          {
            'fields' => {
              'MerchantName' => { 'valueString' => '検証店' },
              'Total' => { 'valueCurrency' => { 'amount' => 300 } },
              'CountryRegion' => { 'valueString' => 'JPN' },
              'Items' => { 'valueArray' => [ item ] }
            }
          }
        ]
      }
    }
    Ocr::ResponseParser.new(response: response, provider: 'azure').call
  end

  it '商品内の地名で任意の住所欠損を残さず、日時や支払の要確認は維持する' do
    receipt = create(:receipt, :processing, :with_image)
    run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(run, parsed_product_locality)
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

  it '決済metadataの見出しを住所と誤認せず、別の未解決理由を維持する' do
    receipt = create(:receipt, :processing, :with_image)
    run = Receipts::Processing.start(receipt: receipt, source: 'upload').run
    source = parsed_product_locality
    source[:lines] << '商品区分'
    Receipts::Processing.record_ocr_snapshot(run, source)
    Receipts::Processing.record_ai_normalized_result(
      run,
      {
        success: true, needs_review: true,
        review_reasons: [ 'store_address_missing' ],
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
      expect(receipt.reload).to have_attributes(status: 'review_needed', total_amount: 300, store_address: nil)
      expect(receipt.review_reasons).to include('purchased_at_missing', 'payment_method_missing')
      expect(receipt.review_reasons).not_to include('store_address_missing')
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
        replacement = Struct.new(:signal_address_pattern, :signal_phone_pattern, :analysis_fallback_payment_metadata_label_pattern)
          .new(/CONTACT-ADDRESS/, /CONTACT-PHONE/, /PAYMENT-METADATA/)
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

      context '決済metadataの見出し' do
        it '行全体が既存の見出しだけなら住所欠損を解除する' do
          [ '商品区分', '取扱区分', '  商品区分  ', '　取扱区分　' ].each do |label|
            ocr_result[:lines] = [ label ]

            expect(resolve_missing_reason).to be_empty
          end
        end

        it '見出しの前後に住所や値がある行、未知の見出しを除外しない' do
          [ "商品区分 #{printed_value}", "#{printed_value} 取扱区分", '商品区分 001', '検証商品区分', '未定義区分' ].each do |line|
            ocr_result[:lines] = [ line ]

            expect(resolve_missing_reason).to eq([ reason ])
          end
        end

        it '別行にある住所の根拠を維持する' do
          ocr_result[:lines] = [ '商品区分', printed_value ]

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '構造化住所がある場合は見出しだけでも欠損を維持する' do
          ocr_result[:lines] = [ '商品区分' ]
          ocr_result[:candidates][:store_address_components] = { city: '検証市' }

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '省略されたOCRで住所なしと判断しない' do
          ocr_result[:lines] = [ '商品区分' ]
          ocr_result[:truncated] = { lines: true }

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '除外する見出しも注入されたprofileから取得する' do
          replacement = ReceiptAnalysisProfiles.default.dup
          replacement.define_singleton_method(:analysis_fallback_payment_metadata_label_pattern) { /検証区分/ }
          allow(ReceiptAnalysisProfiles).to receive(:default).and_return(replacement)
          ocr_result[:lines] = [ '検証区分' ]

          expect(resolve_missing_reason).to be_empty
          ocr_result[:lines] = [ '商品区分' ]
          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '住所用の除外を電話番号に流用しない' do
          replacement = ReceiptAnalysisProfiles.default.dup
          replacement.define_singleton_method(:analysis_fallback_payment_metadata_label_pattern) { /03-0000-0000/ }
          allow(ReceiptAnalysisProfiles).to receive(:default).and_return(replacement)
          ocr_result[:lines] = [ '03-0000-0000' ]

          expect(step.send(:remove_resolved_store_phone_number_missing_review_reason, [ 'store_phone_number_missing' ], params, ocr_result))
            .to eq([ 'store_phone_number_missing' ])
        end
      end

      context '商品説明に地名がある場合' do
        let(:description_ref) { { line_index: 1, character_offset: 0, character_length: 6 } }

        before do
          ocr_result[:lines][1] = '検証市指定券 300'
          ocr_result[:candidates][:items] = [ { raw_text: '検証市指定券', description_source_refs: [ description_ref ] } ]
        end

        it '正確な商品説明の範囲に属する地名だけなら住所欠損を解除する' do
          expect(resolve_missing_reason).to be_empty
        end

        it '商品コードを含む住所patternの一致でもDescriptionの地名だけを除外する' do
          ocr_result[:lines][1] = '001 検証市指定券 300'
          description_ref[:character_offset] = 4

          expect(resolve_missing_reason).to be_empty
        end

        it '同じ行でも商品説明の範囲外に実住所があれば欠損を維持する' do
          ocr_result[:lines][1] += " #{printed_value}"

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '別行の住所の根拠を商品説明と一緒に除外しない' do
          ocr_result[:lines] << printed_value

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '構造化住所の根拠を商品説明の地名で無効にしない' do
          ocr_result[:candidates][:store_address_components] = { city: '検証市' }

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '所有範囲が保存されていない旧OCRでは地名を推測で除外しない' do
          ocr_result[:candidates][:items].first.delete(:description_source_refs)

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '範囲内でも商品説明と一致しない参照では欠損を維持する' do
          description_ref[:character_offset] = 1

          expect(resolve_missing_reason).to eq([ reason ])
        end

        [
          { line_index: -1 },
          { line_index: 99 },
          { character_offset: -1 },
          { character_length: 0 },
          { character_length: 1000 },
          { character_length: '6' },
          { extra: true }
        ].each do |invalid_attributes|
          it "不正な所有範囲#{invalid_attributes.inspect}で欠損を解除しない" do
            description_ref.merge!(invalid_attributes)

            expect(resolve_missing_reason).to eq([ reason ])
          end
        end

        it '別商品と重なる所有範囲を根拠にしない' do
          ocr_result[:candidates][:items] << { raw_text: '別の検証品', description_source_refs: [ description_ref.dup ] }

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '所有範囲が上限を超えた場合は一部だけを採用しない' do
          ocr_result[:lines][1] += 'x' * 20
          refs = ocr_result[:candidates][:items].first[:description_source_refs]
          refs.concat(16.times.map { |index| { line_index: 1, character_offset: index + 6, character_length: 1 } })

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '商品数が所有根拠の上限を超える場合は除外しない' do
          ocr_result[:candidates][:items].concat(Array.new(100) { { raw_text: '検証品' } })

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '行数が所有根拠の上限を超える場合は除外しない' do
          ocr_result[:lines].concat(Array.new(148, '検証行'))

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '商品説明の除外にも差替えprofileの住所判定を使う' do
          replacement = Struct.new(:signal_address_pattern, :signal_phone_pattern, :analysis_fallback_payment_metadata_label_pattern)
            .new(/contact-address/, /contact-phone/, /payment-metadata/)
          allow(ReceiptAnalysisProfiles).to receive(:default).and_return(replacement)
          description = 'CONTACT-ADDRESS用商品'
          ocr_result[:lines][1] = "#{description.downcase} 300"
          ocr_result[:candidates][:items].first[:raw_text] = description
          description_ref[:character_length] = description.length

          expect(resolve_missing_reason).to be_empty
          ocr_result[:lines] << 'contact-address'
          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '省略されたOCRでは商品説明以外の住所がないと判断しない' do
          ocr_result[:truncated] = { lines: true }

          expect(resolve_missing_reason).to eq([ reason ])
        end

        it '商品説明の所有範囲を電話番号の判定へ流用しない' do
          ocr_result[:lines][1] = '03-0000-0000'
          description_ref[:character_length] = 11

          expect(step.send(:remove_resolved_store_phone_number_missing_review_reason, [ 'store_phone_number_missing' ], params, ocr_result))
            .to eq([ 'store_phone_number_missing' ])
        end
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
