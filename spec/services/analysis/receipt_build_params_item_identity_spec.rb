require 'rails_helper'

RSpec.describe Analysis::ReceiptBuildParamsService do
  describe '.call' do
    let(:ocr_result) do
      {
        candidates: {
          store_name: 'サンプルストア',
          total_amount: 600,
          items: [
            { raw_text: 'ノート A5', price: 220, line_total: 220, quantity: 1, category: 'hobby', tax_rate: 0.1 },
            { raw_text: '飲料 1000mL', price: 380, line_total: 380, quantity: 1, category: 'drink', tax_rate: 0.1 }
          ]
        },
        lines: [ 'ノート A5 220', '飲料 1000mL 380', '合計 600' ]
      }
    end
    let(:ai_result) do
      { meta: { ai_name_completion_enabled: true }, receipt_items_attributes: [] }
    end

    def build_items
      described_class.call(ocr_result: ocr_result, ai_result: ai_result).fetch(:receipt_items_attributes)
    end

    it 'index 0が省略されてもindex 1を2番目のOCR明細へ関連付ける' do
      ai_result[:receipt_items_attributes] = [
        { index: 1, suggested_name: '飲料 1000ml', category: 'food', needs_review: false }
      ]

      items = build_items

      aggregate_failures do
        expect(items.first).to include(raw_text: 'ノート A5', suggested_name: 'ノート A5', category: 'hobby', line_total: 220)
        expect(items.second).to include(raw_text: '飲料 1000mL', suggested_name: '飲料 1000ml', category: 'food', line_total: 380)
      end
    end

    it 'OCR件数と同じindexを1-based末尾と推測せず拒否する' do
      ai_result[:receipt_items_attributes] = [ { index: 2, suggested_name: '飲料 1000mL', category: 'food' } ]

      items = build_items

      aggregate_failures do
        expect(items.pluck(:category)).to eq(%w[hobby drink])
        expect(items.first[:review_reasons]).to include('item_name_uncertain')
      end
    end

    [ 1.5, '1.5', Float::NAN, Float::INFINITY, -1, true, nil ].each do |invalid_index|
      it "不正index #{invalid_index.inspect}を別の整数indexへ変換しない" do
        ai_result[:receipt_items_attributes] = [
          { index: invalid_index, suggested_name: 'ノート A5', category: 'food', needs_review: false }
        ]

        items = build_items

        aggregate_failures do
          expect(items.pluck(:category)).to eq(%w[hobby drink])
          expect(items.pluck(:line_total)).to eq([ 220, 380 ])
          expect(items.first[:review_reasons]).to include('item_name_uncertain')
          expect(items.first[:needs_review]).to be(true)
        end
      end
    end

    it '欠損indexの提案をnormalizer経由でも採用せず確認理由を保持する' do
      ai_result[:receipt_items_attributes] = Analysis.normalize_receipt_items([
        { index: 1.5, suggested_name: 'ノート A5', category: 'food' }
      ])

      items = build_items

      aggregate_failures do
        expect(items.pluck(:category)).to eq(%w[hobby drink])
        expect(items.first[:review_reasons]).to include('item_name_uncertain')
      end
    end

    it '明示された不正indexをposition_indexで補って採用しない' do
      ai_result[:receipt_items_attributes] = [
        { index: nil, position_index: 0, suggested_name: 'ノート A5', category: 'food' }
      ]

      items = build_items

      aggregate_failures do
        expect(items.pluck(:category)).to eq(%w[hobby drink])
        expect(items.first[:review_reasons]).to include('item_name_uncertain')
      end
    end

    it '巨大文字列・非ASCII互換encodingのindexを整数へ変換しない' do
      [ '0' * 128, '1'.encode(Encoding::UTF_16LE) ].each do |index|
        ai_result[:receipt_items_attributes] = [ { index: index, category: 'food' } ]

        items = build_items

        aggregate_failures do
          expect(items.pluck(:category)).to eq(%w[hobby drink])
          expect(items.first[:review_reasons]).to include('item_name_uncertain')
        end
      end
    end

    it '同じindexが複数ある提案は全件拒否し他indexだけを適用する' do
      ai_result[:receipt_items_attributes] = [
        { index: 0, suggested_name: 'ノートa5', category: 'food', tax_rate: 0.08, needs_review: false },
        { index: 0, suggested_name: 'ノート A5', category: 'other', tax_rate: 0, needs_review: false },
        { index: 1, suggested_name: '飲料1000ml', category: 'food', needs_review: false }
      ]

      items = build_items

      aggregate_failures do
        expect(items.first).to include(suggested_name: 'ノート A5', category: 'hobby', tax_rate: BigDecimal('0.1'), needs_review: true)
        expect(items.first[:review_reasons]).to include('item_name_uncertain')
        expect(items.second).to include(suggested_name: '飲料1000ml', category: 'food')
      end
    end

    it '同一商品名のNFKC・空白・大小文字の表記補正を受け付ける' do
      ai_result[:receipt_items_attributes] = [ { index: 0, suggested_name: 'ノートＡ５', category: 'hobby', needs_review: false } ]

      item = build_items.first

      aggregate_failures do
        expect(item).to include(raw_text: 'ノート A5', suggested_name: 'ノートＡ５', line_total: 220, needs_review: false)
        expect(item[:review_reasons]).not_to include('item_name_uncertain')
      end
    end

    [ [ 0, 'ノート' ], [ 0, 'ノート A4' ], [ 0, '限定ノート A5' ], [ 1, '飲料' ], [ 1, '飲料 500mL' ] ].each do |index, name|
      it "商品名identityを変える #{name} を採用しない" do
        ai_result[:receipt_items_attributes] = [ { index: index, suggested_name: name, category: 'hobby', needs_review: false } ]

        item = build_items[index]

        aggregate_failures do
          expect(item[:suggested_name]).to eq(ocr_result[:candidates][:items][index][:raw_text])
          expect(item[:review_reasons]).to include('item_name_uncertain')
          expect(item[:needs_review]).to be(true)
        end
      end
    end

    it '一致部分のある別明細行を商品名の補完根拠にしない' do
      ocr_result[:lines].unshift('限定ノート A5 330')
      ai_result[:receipt_items_attributes] = [ { index: 0, suggested_name: '限定ノート A5', needs_review: false } ]

      expect(build_items.first).to include(suggested_name: 'ノート A5', needs_review: true)
    end

    it 'Price由来のsource lineやspanを商品名の根拠にしない' do
      ocr_result[:candidates][:items].first.merge!(
        source_field_path: 'documents[0].fields.Items[0].Price', source_line_index: 1,
        source_span_start: 12, source_span_end: 15
      )
      ai_result[:receipt_items_attributes] = [ { index: 0, suggested_name: '飲料 1000mL', needs_review: false } ]

      expect(build_items.first).to include(suggested_name: 'ノート A5', needs_review: true)
    end

    it 'source_textをname-onlyの代わりに商品名の根拠にしない' do
      ocr_result[:candidates][:items].first[:source_text] = '限定ノート A5'
      ai_result[:receipt_items_attributes] = [ { index: 0, suggested_name: '限定ノート A5', needs_review: false } ]

      expect(build_items.first).to include(suggested_name: 'ノート A5', needs_review: true)
    end

    it 'fallbackの金額付きraw lineをname-onlyの代わりに採用しない' do
      ocr_result[:candidates][:items] = []
      ai_result[:receipt_items_attributes] = [ { index: 0, suggested_name: 'ノート A5 220', needs_review: false } ]

      expect(build_items.first).to include(raw_text: 'ノート A5 220', suggested_name: 'ノート A5', needs_review: true)
    end

    [ false, nil, 'true' ].each do |flag|
      it "商品名補完が明示trueでない #{flag.inspect} の場合はOCR表記を保持する" do
        ai_result[:meta] = { ai_name_completion_enabled: flag }
        ai_result[:receipt_items_attributes] = [ { index: 0, suggested_name: 'ノートa5', category: 'food', needs_review: false } ]

        item = build_items.first

        aggregate_failures do
          expect(item).to include(suggested_name: 'ノート A5', category: 'food', needs_review: false)
          expect(item[:review_reasons]).not_to include('item_name_uncertain')
        end
      end
    end

    it 'metaがないold payloadでは商品名補完を有効にしない' do
      ai_result.delete(:meta)
      ai_result[:receipt_items_attributes] = [ { index: 0, suggested_name: '限定ノート A5', needs_review: false } ]

      expect(build_items.first).to include(suggested_name: 'ノート A5', needs_review: false)
    end
  end
end
