require 'spec_helper'
require 'json'
require_relative '../../../app/services/analysis'
require_relative '../../../app/services/analysis/payment_method_evidence'

RSpec.describe Analysis::PaymentMethodEvidence do
  let(:profile) do
    double(
      ocr_payment_method_label_pattern: /\Asale\z/,
      ocr_payment_schedule_value_pattern: /\Aone installment\z/,
      ocr_payment_support_only_pattern: /available/,
      analysis_fallback_payment_transaction_context_pattern: /sale|settlement/,
      analysis_return_refund_kind_pattern: /refund/,
      ocr_payment_method_value_patterns: { 'e_money' => /\Asample pay\z/, 'credit_card' => /\Asample card\z/ }
    )
  end
  let(:lines) { [ 'sale', 'sample pay' ] }
  let(:evidence) do
    {
      source_kind: 'azure_same_row', method: 'e_money', page_index: 0,
      label_line_index: 0, method_line_index: 1,
      label_path: 'pages[0].lines[2]', method_path: 'pages[0].lines[3]',
      label_span: { offset: 20, length: 4 }, method_span: { offset: 25, length: 10 },
      string_index_type: 'textElements'
    }
  end

  def validate(value = evidence, source_lines: lines)
    described_class.call(value, lines: source_lines, profile: profile)
  end

  it 'normalizes a bounded provider proof without mutating or sharing its input' do
    input = JSON.parse(JSON.generate(evidence))
    original = JSON.generate(input)
    result = validate(input)

    aggregate_failures do
      expect(result).to eq(evidence)
      expect(JSON.generate(input)).to eq(original)
      expect(result).to be_frozen
      expect(result[:label_span]).to be_frozen
      expect(result[:method]).to be_frozen
      expect(input['method']).not_to be_frozen
    end
  end

  it 'accepts both existing provider index types' do
    expect(validate(evidence.merge(string_index_type: 'utf16CodeUnit'))).to include(method: 'e_money')
  end

  {
    'missing proof' => ->(_value) { nil },
    'multiple proofs' => ->(value) { [ value, value ] },
    'unknown field' => ->(value) { value.merge(raw_text: 'untrusted') },
    'duplicate normalized key' => ->(value) { value.merge('method' => 'e_money') },
    'incomplete fields' => ->(value) { value.reject { |key, _| key == :label_span } },
    'unknown source' => ->(value) { value.merge(source_kind: 'inferred') },
    'unknown method' => ->(value) { value.merge(method: 'unknown') },
    'method not matching the evidence' => ->(value) { value.merge(method: 'credit_card') },
    'negative page' => ->(value) { value.merge(page_index: -1) },
    'page above the bound' => ->(value) { value.merge(page_index: 8) },
    'noninteger index' => ->(value) { value.merge(label_line_index: 0.0) },
    'nonconsecutive normalized lines' => ->(value) { value.merge(method_line_index: 2) },
    'different page path' => ->(value) { value.merge(method_path: 'pages[1].lines[3]') },
    'nonconsecutive provider lines' => ->(value) { value.merge(method_path: 'pages[0].lines[4]') },
    'noncanonical path' => ->(value) { value.merge(label_path: 'pages[00].lines[2]') },
    'negative span' => ->(value) { value.merge(label_span: { offset: -1, length: 4 }) },
    'empty span' => ->(value) { value.merge(label_span: { offset: 20, length: 0 }) },
    'overlapping span' => ->(value) { value.merge(method_span: { offset: 23, length: 10 }) },
    'span longer than a bounded provider line' => ->(value) { value.merge(method_span: { offset: 25, length: 501 }) },
    'overflowing span' => ->(value) { value.merge(method_span: { offset: 9_999_999, length: 10 }) },
    'extra span data' => ->(value) { value.merge(label_span: { offset: 20, length: 4, text: 'untrusted' }) },
    'unsupported index type' => ->(value) { value.merge(string_index_type: 'unicodeCodePoint') }
  }.each do |description, change|
    it "rejects #{description}" do
      expect(validate(change.call(evidence))).to be_nil
    end
  end

  {
    'unrelated heading' => [ 'heading', 'sample pay' ],
    'label embedded in text' => [ 'sale advertisement', 'sample pay' ],
    'instrument embedded in text' => [ 'sale', 'sample pay available' ],
    'absent source line' => [ 'sale' ],
    'line above the byte bound' => [ 'sale', 'x' * 501 ],
    'too many lines' => [ 'sale', 'sample pay' ] + Array.new(149, 'other'),
    'control character' => [ 'sale', "sample pay\0" ],
    'binary non-ASCII text' => [ 'sale', "\xff".b ],
    'invalid encoding' => [ 'sale', "\xff".force_encoding(Encoding::UTF_8) ]
  }.each do |description, source_lines|
    it "rejects #{description}" do
      expect(validate(source_lines: source_lines)).to be_nil
    end
  end

  it 'requires one matching method rather than profile pattern priority' do
    allow(profile).to receive(:ocr_payment_method_value_patterns).and_return(
      'e_money' => /\Asample pay\z/, 'credit_card' => /\Asample pay\z/
    )

    expect(validate).to be_nil
  end

  it 'rejects multiple transaction method pairs even when their categories agree' do
    expect(validate(source_lines: lines + lines)).to be_nil
  end

  it 'ignores only a complete recognized payment schedule pair' do
    expect(validate(source_lines: lines + [ 'sale', 'one installment' ])).to include(method: 'e_money')
  end

  it 'rejects another method label with an unknown value' do
    expect(validate(source_lines: lines + [ 'sale', 'unknown method' ])).to be_nil
  end

  it 'rejects another method label without a value' do
    expect(validate(source_lines: lines + [ 'sale' ])).to be_nil
  end

  it 'does not ignore a schedule name embedded in another value' do
    expect(validate(source_lines: lines + [ 'sale', 'one installment other' ])).to be_nil
  end

  it 'rejects support-only statements anywhere in the complete source' do
    expect(validate(source_lines: lines + [ 'sample card avail able' ])).to be_nil
  end

  it 'uses the injected support vocabulary without treating every footer as a conflict' do
    expect(validate(source_lines: lines + [ 'thank you', 'ご利用いただけます' ])).to include(method: 'e_money')
  end

  it 'uses injected profile vocabulary instead of Japanese receipt labels' do
    expect(validate(source_lines: [ '売上', 'sample pay' ])).to be_nil
    expect(validate).to include(method: 'e_money')
  end

  it 'rejects another transaction context without a recognized method' do
    expect(validate(source_lines: lines + [ 'settlement unknown' ])).to be_nil
  end

  it 'rejects refund evidence outside the protected pair' do
    expect(validate(source_lines: lines + [ 'refund 600' ])).to be_nil
  end

  it 'keeps numeric metadata independent of method evidence and uses injected conflict patterns' do
    expect(validate(source_lines: lines + [ 'trace 123456', '精算', '返金' ])).to include(method: 'e_money')
  end
end
