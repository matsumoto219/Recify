require 'rails_helper'

RSpec.describe Receipts::Processing::Contracts::ReferencePricingOcrEvidenceLedger do
  FIXTURE_PATH = Rails.root.join(
    'spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json'
  )

  def parser_result
    @parser_result ||= Ocr::ResponseParser.new(
      response: JSON.parse(FIXTURE_PATH.read),
      provider: :fixture
    ).call
  end

  def first_option
    parser_result.dig(:evidence_options, :reference_pricing).sole.deep_dup
  end

  def base_snapshot(line_count: 6)
    {
      'schema_version' => 'receipt_analysis_run_ocr_result_v1',
      'success' => true,
      'lines' => Array.new(line_count) { |index| "SYNTH-#{index}" },
      'case_preserved_lines' => Array.new(line_count) { |index| "SYNTH-#{index}" },
      'truncated' => {
        'lines' => false,
        'case_preserved_lines' => false
      }
    }
  end

  def build(options = [ first_option ], ocr_snapshot: base_snapshot)
    described_class.build(options:, ocr_snapshot:)
  end

  def shifted_option
    option = first_option
    option[:candidate_id] = "azure_line_group_evidence_v1_#{Digest::SHA256.hexdigest('second')}"
    option[:destination_id] = 'azure_line_group_destination_p0_name_l3_s63_e69_ref_l3_qty_l4'
    option[:reference_line_index] = 3
    option[:purchased_quantity_line_index] = 4
    option[:handles].each_with_index do |handle, index|
      line_index = handle[:role] == 'purchased_quantity' ? 4 : 3
      span_delta = 50
      handle[:handle_id] = "reference_pricing_handle_v1_#{Digest::SHA256.hexdigest("second-#{index}")}"
      handle[:source_field_path] = "pages[0].lines[#{line_index}]"
      handle[:line_index] = line_index
      handle[:provider_span_start] += span_delta
      handle[:provider_span_end] += span_delta
    end
    option
  end

  it 'builds a deterministic, value-free, versioned ledger from bounded structural options' do
    ledger = build([ shifted_option, first_option ])

    aggregate_failures do
      expect(ledger.keys).to eq(%w[
        schema_version
        creation_stage
        option_count
        handle_count
        options
        integrity_checksum
      ])
      expect(ledger).to include(
        'schema_version' => 'reference_pricing_ocr_evidence_ledger_v1',
        'creation_stage' => 'ocr_validation',
        'option_count' => 2,
        'handle_count' => 10,
        'integrity_checksum' => match(/\A[0-9a-f]{64}\z/)
      )
      expect(ledger.fetch('options').pluck('reference_line_index')).to eq([ 1, 3 ])
      expect(ledger.fetch('options').flat_map { |option| option.fetch('handles') }.pluck('role')).to eq(
        %w[product_destination reference_price reference_quantity purchased_quantity tax_inclusion] * 2
      )
      expect(JSON.generate(ledger).bytesize).to be <= described_class::MAX_SERIALIZED_BYTES
    end
  end

  it 'round-trips through JSON and stored snapshot validation without semantic loss' do
    ledger = build
    parsed = JSON.parse(JSON.generate(ledger))

    expect(described_class.from_snapshot(parsed, ocr_snapshot: base_snapshot)).to eq(ledger)
  end

  it 'does not persist OCR text, numeric authority, units, tax decisions, polygons, or arbitrary metadata' do
    option = first_option
    option[:raw_text] = '保存禁止OCR全文'
    option[:amount] = '120'
    option[:quantity] = '2.5'
    option[:unit_code] = 'liter'
    option[:tax] = 'gross'
    option[:polygon] = [ 0, 0, 1, 1 ]
    option[:metadata] = { arbitrary: true }

    expect(build([ option ])).to be_nil
  end

  it 'rejects unknown versions and unknown keys at every level' do
    ledger = build
    unknown_root = ledger.merge('unknown' => true)
    unknown_version = ledger.merge('schema_version' => 'reference_pricing_ocr_evidence_ledger_v2')
    unknown_option = ledger.deep_dup
    unknown_option.dig('options', 0)['unknown'] = true
    unknown_handle = ledger.deep_dup
    unknown_handle.dig('options', 0, 'handles', 0)['unknown'] = true

    expect([
      described_class.from_snapshot(unknown_root, ocr_snapshot: base_snapshot),
      described_class.from_snapshot(unknown_version, ocr_snapshot: base_snapshot),
      described_class.from_snapshot(unknown_option, ocr_snapshot: base_snapshot),
      described_class.from_snapshot(unknown_handle, ocr_snapshot: base_snapshot)
    ]).to all(be_nil)
  end

  it 'rejects duplicate option and handle identities instead of deduplicating or truncating' do
    duplicate_candidate = [ first_option, shifted_option ]
    duplicate_candidate.last[:candidate_id] = duplicate_candidate.first[:candidate_id]
    duplicate_destination = [ first_option, shifted_option ]
    duplicate_destination.last[:destination_id] = duplicate_destination.first[:destination_id]
    duplicate_handle = first_option
    duplicate_handle[:handles][1][:handle_id] = duplicate_handle[:handles][0][:handle_id]

    expect([
      build(duplicate_candidate),
      build(duplicate_destination),
      build([ duplicate_handle ])
    ]).to all(be_nil)
  end

  it 'rejects unknown enums, malformed identities, and path/index mismatches' do
    mutations = [
      ->(option) { option[:source_kind] = 'azure_structured' },
      ->(option) { option[:provider_model_id] = 'unknown-model' },
      ->(option) { option[:provider_api_version] = '2099-01-01' },
      ->(option) { option[:string_index_type] = 'utf8Byte' },
      ->(option) { option[:validation_contract_version] = 'unknown-contract' },
      ->(option) { option[:candidate_id] = 'azure_line_group_p0_l1_l2_reference_pricing' },
      ->(option) { option[:destination_id] = 'malformed' },
      ->(option) { option[:handles][0][:role] = 'merchant' },
      ->(option) { option[:handles][0][:source_field_path] = 'pages[0].lines[9]' },
      ->(option) { option[:handles][0][:line_index] = 9 },
      ->(option) { option[:handles][0][:string_index_type] = 'utf16CodeUnit' }
    ]

    results = mutations.map do |mutation|
      option = first_option
      mutation.call(option)
      build([ option ])
    end

    expect(results).to all(be_nil)
  end

  it 'rejects malformed spans, missing roles, and line association drift' do
    mutations = [
      ->(option) { option[:handles][0][:provider_span_start] = -1 },
      ->(option) { option[:handles][0][:provider_span_end] = option[:handles][0][:provider_span_start] },
      ->(option) { option[:handles][0][:provider_span_end] = 10_000_001 },
      ->(option) { option[:handles].pop },
      ->(option) { option[:handles][1][:role] = option[:handles][0][:role] },
      ->(option) { option[:reference_line_index] = 2 },
      ->(option) { option[:purchased_quantity_line_index] = 3 },
      ->(option) { option[:page_index] = 1 }
    ]

    results = mutations.map do |mutation|
      option = first_option
      mutation.call(option)
      build([ option ])
    end

    expect(results).to all(be_nil)
  end

  it 'rejects a changed checksum, count, or referenced OCR structure' do
    ledger = build
    bad_checksum = ledger.merge('integrity_checksum' => '0' * 64)
    bad_option_count = ledger.merge('option_count' => 2)
    bad_handle_count = ledger.merge('handle_count' => 4)
    truncated = base_snapshot.deep_merge('truncated' => { 'lines' => true })
    too_few_lines = base_snapshot(line_count: 2)

    expect([
      described_class.from_snapshot(bad_checksum, ocr_snapshot: base_snapshot),
      described_class.from_snapshot(bad_option_count, ocr_snapshot: base_snapshot),
      described_class.from_snapshot(bad_handle_count, ocr_snapshot: base_snapshot),
      described_class.from_snapshot(ledger, ocr_snapshot: truncated),
      described_class.from_snapshot(ledger, ocr_snapshot: too_few_lines)
    ]).to all(be_nil)
  end

  it 'rejects the whole ledger above option or serialized byte bounds' do
    too_many = Array.new(described_class::MAX_OPTIONS + 1) do |index|
      option = first_option
      digest = Digest::SHA256.hexdigest("candidate-#{index}")
      option[:candidate_id] = "azure_line_group_evidence_v1_#{digest}"
      option[:destination_id] = "azure_line_group_destination_p0_name_l1_s13_e19_ref_l1_qty_l2_#{index}"
      option
    end

    stub_const("#{described_class}::MAX_SERIALIZED_BYTES", 100)

    aggregate_failures do
      expect(build(too_many)).to be_nil
      expect(build).to be_nil
    end
  end

  it 'fails closed for empty, malformed, invalid-encoding, and control-character payloads' do
    invalid_utf8 = first_option
    invalid_utf8[:candidate_id] = "bad\xFF".force_encoding(Encoding::UTF_8)
    control = first_option
    control[:candidate_id] = "bad\0identity"

    expect([
      described_class.build(options: [], ocr_snapshot: base_snapshot),
      described_class.build(options: {}, ocr_snapshot: base_snapshot),
      described_class.build(options: [ nil ], ocr_snapshot: base_snapshot),
      build([ invalid_utf8 ]),
      build([ control ])
    ]).to all(be_nil)
  end
end
