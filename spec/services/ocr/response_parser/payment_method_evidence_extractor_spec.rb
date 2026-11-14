require 'rails_helper'

RSpec.describe Ocr::ResponseParser::PaymentMethodEvidenceExtractor do
  let(:profile) { ReceiptAnalysisProfiles.default }
  let(:texts) { [ 'Sample Store', '売上', 'iD', '合計 600' ] }
  let(:fields) { {} }
  let(:analyze_result) do
    offset = 0
    lines = texts.each_with_index.map do |text, index|
      left, top, right = case index
      when 1 then [ 100, 200, 200 ]
      when 2 then [ 300, 200, 400 ]
      else [ 100, 100 + index * 100, 500 ]
      end
      line = {
        'content' => text, 'spans' => [ { 'offset' => offset, 'length' => text.length } ],
        'polygon' => [ left, top, right, top, right, top + 40, left, top + 40 ]
      }
      offset += text.length + 1
      line
    end
    {
      'content' => texts.join("\n"), 'stringIndexType' => 'textElements',
      'modelId' => 'prebuilt-receipt', 'apiVersion' => '2024-11-30',
      'pages' => [ { 'width' => 1_000, 'height' => 2_000, 'lines' => lines } ]
    }
  end

  def extract
    described_class.call(
      analyze_result: analyze_result, fields: fields,
      lines: texts.map { |text| text.unicode_normalize(:nfkc).downcase }, profile: profile
    )
  end

  it 'retains only the exact structural proof for one label and value on the same printed row' do
    original = analyze_result.deep_dup
    result = extract

    aggregate_failures do
      expect(result).to eq(
        source_kind: 'azure_same_row', method: 'e_money', page_index: 0,
        label_line_index: 1, method_line_index: 2,
        label_path: 'pages[0].lines[1]', method_path: 'pages[0].lines[2]',
        label_span: { offset: 13, length: 2 }, method_span: { offset: 16, length: 2 },
        string_index_type: 'textElements'
      )
      expect(result.to_json).not_to include('Sample Store', 'iD', '売上', 'polygon', 'content')
      expect(analyze_result).to eq(original)
    end
  end

  it 'does not treat the next printed row as a label and value association' do
    analyze_result['pages'][0]['lines'][2]['polygon'] = [ 300, 260, 400, 260, 400, 300, 300, 300 ]

    expect(extract).to be_nil
  end

  it 'uses the existing half-height overlap boundary for the same printed row' do
    line = analyze_result['pages'][0]['lines'][2]
    line['polygon'] = [ 300, 220, 400, 220, 400, 260, 300, 260 ]
    expect(extract).to include(method: 'e_money')

    line['polygon'] = [ 300, 221, 400, 221, 400, 261, 300, 261 ]
    expect(extract).to be_nil
  end

  it 'rejects a value on another page even when flattened lines are consecutive' do
    page = analyze_result['pages'][0]
    remaining = page['lines'].slice!(2..)
    analyze_result['pages'] << page.merge('lines' => remaining)

    expect(extract).to be_nil
  end

  it 'does not skip an intervening provider line to find a method' do
    texts.insert(2, '補助')

    expect(extract).to be_nil
  end

  it 'rejects a second label and value instead of choosing the first pair' do
    texts.concat([ '支払方法', 'PayPay' ])
    lines = analyze_result['pages'][0]['lines']
    lines[4]['polygon'] = [ 100, 600, 200, 600, 200, 640, 100, 640 ]
    lines[5]['polygon'] = [ 300, 600, 400, 600, 400, 640, 300, 640 ]

    expect(extract).to be_nil
  end

  it 'keeps the instrument proof when another same-row pair describes only the payment schedule' do
    texts.concat([ '支払方法', '一括' ])
    lines = analyze_result['pages'][0]['lines']
    lines[4]['polygon'] = [ 100, 600, 200, 600, 200, 640, 100, 640 ]
    lines[5]['polygon'] = [ 300, 600, 400, 600, 400, 640, 300, 640 ]

    expect(extract).to include(method: 'e_money', label_line_index: 1, method_line_index: 2)
  end

  [ 'UnknownPay', '一括 Cash' ].each do |value|
    it "does not discard another label with an unrecognized or partial schedule value #{value.inspect}" do
      texts.concat([ '支払方法', value ])
      lines = analyze_result['pages'][0]['lines']
      lines[4]['polygon'] = [ 100, 600, 200, 600, 200, 640, 100, 640 ]
      lines[5]['polygon'] = [ 300, 600, 400, 600, 400, 640, 300, 640 ]

      expect(extract).to be_nil
    end
  end

  { 'modelId' => 'prebuilt-document', 'apiVersion' => '2023-07-31' }.each do |field, unsupported|
    it "requires the supported #{field} rather than assuming future provider semantics" do
      analyze_result[field] = unsupported
      expect(extract).to be_nil

      analyze_result.delete(field)
      expect(extract).to be_nil
    end
  end

  it 'rejects another explicitly printed payment method' do
    texts[3] = '現金支払 600円'

    expect(extract).to be_nil
  end

  it 'excludes the strict proof when a support advertisement appears elsewhere on the receipt' do
    texts[3] = 'PayPay使えます'

    expect(extract).to be_nil
  end

  it 'does not promote the instrument beneath a supported-payment advertisement' do
    texts[0] = 'ご利用いただけます'
    texts[1] = '決済方法'

    expect(extract).to be_nil
  end

  it 'rejects support advertising even when it is printed on another page' do
    texts[3] = 'we accept cash'
    page = analyze_result['pages'][0]
    footer = page['lines'].pop
    analyze_result['pages'] << page.merge('lines' => [ footer ])

    expect(extract).to be_nil
  end

  it 'does not classify a bare card network as credit in the presence of explicit debit evidence' do
    texts[0] = 'VISAデビット'
    texts[2] = 'VISA'

    expect(extract).to be_nil
  end

  it 'retains explicit credit classification without inferring it from a card network' do
    texts[2] = 'クレジットカード'

    expect(extract).to include(method: 'credit_card')
  end

  it 'rejects a conflicting structured payment without changing the existing field' do
    fields['Payments'] = { 'valueArray' => [ { 'valueObject' => { 'Method' => { 'valueString' => 'VISA' } } } ] }
    original = fields.deep_dup

    aggregate_failures do
      expect(extract).to be_nil
      expect(fields).to eq(original)
    end
  end

  it 'rejects malformed structured payment values without raising' do
    fields['Payments'] = { 'valueArray' => [ { 'valueObject' => { 'Method' => 'invalid' } } ] }

    expect(extract).to be_nil
  end

  %w[Items MerchantName].each do |owner|
    it "rejects a method span owned by #{owner}" do
      fields[owner] = { 'content' => 'iD', 'spans' => analyze_result['pages'][0]['lines'][2]['spans'] }

      expect(extract).to be_nil
    end
  end

  it 'rejects an unlocated merchant field instead of assuming it is unrelated' do
    fields['MerchantName'] = { 'content' => 'iD', 'valueString' => 'iD' }

    expect(extract).to be_nil
  end

  it 'rejects an owner without any spans even when another owner is located' do
    fields['MerchantName'] = { 'valueString' => 'Sample Store', 'spans' => [ { 'offset' => 0, 'length' => 12 } ] }
    fields['Items'] = { 'valueArray' => [ { 'valueObject' => { 'Description' => { 'valueString' => 'iD' } } } ] }

    expect(extract).to be_nil
  end

  it 'rejects another line overlapping the label/value block' do
    analyze_result['pages'][0]['lines'][0]['polygon'] = [ 220, 200, 280, 200, 280, 240, 220, 240 ]

    expect(extract).to be_nil
  end

  it 'rejects reversed label/value positions' do
    analyze_result['pages'][0]['lines'][2]['polygon'] = [ 0, 200, 80, 200, 80, 240, 0, 240 ]

    expect(extract).to be_nil
  end

  it 'rejects missing, self-crossing and nonfinite polygons' do
    line = analyze_result['pages'][0]['lines'][2]
    aggregate_failures do
      [ nil, [ 300, 200, 400, 240, 400, 200, 300, 240 ], [ Float::INFINITY ] * 8 ].each do |polygon|
        line['polygon'] = polygon
        expect(extract).to be_nil
      end
    end
  end

  it 'rejects negative, oversized, malformed and overlapping spans' do
    line = analyze_result['pages'][0]['lines'][2]
    aggregate_failures do
      [
        { 'offset' => -1, 'length' => 2 },
        { 'offset' => 16, 'length' => 10_000_001 },
        { 'offset' => '16', 'length' => 2 },
        { 'offset' => 13, 'length' => 2 }
      ].each do |span|
        line['spans'] = [ span ]
        expect(extract).to be_nil
      end
    end
  end

  %w[utf16CodeUnit textElements].each do |index_type|
    it "keeps exact provider offsets with Unicode sequences in #{index_type}" do
      texts[0] = "A\u{1F600}e\u0301"
      analyze_result['stringIndexType'] = index_type
      offset = 0
      analyze_result['pages'][0]['lines'].each do |line|
        length = index_type == 'utf16CodeUnit' ? line['content'].encode('UTF-16LE').bytesize / 2 : line['content'].scan(/\X/).size
        line['spans'] = [ { 'offset' => offset, 'length' => length } ]
        offset += length + 1
      end

      expect(extract).to include(string_index_type: index_type, label_span: { offset: index_type == 'utf16CodeUnit' ? 6 : 4, length: 2 })
    end
  end

  it 'rejects unsupported string index types' do
    analyze_result['stringIndexType'] = 'unicodeCodePoint'

    expect(extract).to be_nil
  end

  [ '', 'iD使えます', 'Transaction ID', 'UnknownPay', 'Apple Pay' ].each do |method|
    it "rejects an incomplete or unsupported method value #{method.inspect}" do
      texts[2] = method

      expect(extract).to be_nil
    end
  end

  it 'bounds line text in bytes without truncating the proof' do
    texts[0] = 'あ' * 167

    expect(extract).to be_nil
  end

  it 'bounds pages and total lines before searching pairs' do
    pages = analyze_result['pages']
    pages.concat(Array.new(8) { { 'width' => 1_000, 'height' => 2_000, 'lines' => [] } })
    expect(extract).to be_nil

    pages.slice!(1..)
    pages[0]['lines'].concat(Array.new(147) { pages[0]['lines'][3].deep_dup })
    expect(extract).to be_nil
  end

  it 'rejects control characters and invalid encoding' do
    line = analyze_result['pages'][0]['lines'][2]
    aggregate_failures do
      [ "iD\u0000", "iD\u200B", "\xFF".b.force_encoding('UTF-8') ].each do |value|
        line['content'] = value
        expect(extract).to be_nil
      end
    end
  end

  it 'keeps parser payment amounts and totals unchanged while adding the structural candidate' do
    fields['Total'] = { 'valueCurrency' => { 'amount' => 600 } }
    response = { 'analyzeResult' => analyze_result.merge('documents' => [ { 'fields' => fields } ]) }

    result = Ocr::ResponseParser.new(response: response, provider: :azure).call

    aggregate_failures do
      expect(result.dig(:candidates, :payment_method_evidence)).to include(method: 'e_money')
      expect(result.dig(:candidates, :payments)).to eq([])
      expect(result.dig(:candidates, :total_amount)).to eq(600)
    end
  end

  it 'uses the injected profile for both the label and the complete method value' do
    replacement = profile.dup
    allow(replacement).to receive(:ocr_payment_method_label_pattern).and_return(/\Atransaction\z/)
    allow(replacement).to receive(:ocr_payment_method_value_patterns).and_return('qr_payment' => /\Atoken\z/)
    texts[1] = 'transaction'
    texts[2] = 'token'

    result = described_class.call(analyze_result: analyze_result, fields: fields, lines: texts.map(&:downcase), profile: replacement)

    aggregate_failures do
      expect(result).to include(method: 'qr_payment')
      expect(extract).to be_nil
    end
  end
end
