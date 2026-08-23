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
    described_class.build(
      options:,
      ocr_snapshot:,
      source_lines: ocr_snapshot.fetch('lines'),
      source_case_preserved_lines: ocr_snapshot.fetch('case_preserved_lines')
    )
  end

  def refresh_identities(option)
    option[:handles].each do |handle|
      identity_material = handle.values_at(
        :role,
        :source_field_path,
        :page_index,
        :line_index,
        :string_index_type,
        :provider_span_start,
        :provider_span_end
      )
      handle[:handle_id] = "reference_pricing_handle_v1_#{Digest::SHA256.hexdigest(identity_material.join("\0"))}"
    end
    candidate_material = [
      'azure_line_group_evidence_v1',
      option.fetch(:destination_id),
      *option.fetch(:handles).flat_map do |handle|
        handle.values_at(
          :role,
          :source_field_path,
          :page_index,
          :line_index,
          :string_index_type,
          :provider_span_start,
          :provider_span_end
        )
      end
    ]
    option[:candidate_id] = "azure_line_group_evidence_v1_#{Digest::SHA256.hexdigest(candidate_material.join("\0"))}"
    option
  end

  def shifted_option(ordinal = 1)
    option = first_option
    reference_line_index = 1 + (ordinal * 2)
    purchased_line_index = reference_line_index + 1
    span_delta = ordinal * 50
    name_start = 13 + span_delta
    name_end = 19 + span_delta
    option[:destination_id] = "azure_line_group_destination_p0_name_l#{reference_line_index}_" \
      "s#{name_start}_e#{name_end}_ref_l#{reference_line_index}_qty_l#{purchased_line_index}"
    option[:reference_line_index] = reference_line_index
    option[:purchased_quantity_line_index] = purchased_line_index
    option[:handles].each_with_index do |handle, index|
      line_index = handle[:role] == 'purchased_quantity' ? purchased_line_index : reference_line_index
      handle[:source_field_path] = "pages[0].lines[#{line_index}]"
      handle[:line_index] = line_index
      handle[:provider_span_start] += span_delta
      handle[:provider_span_end] += span_delta
    end
    refresh_identities(option)
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

  it 'binds the checksum to the complete stored OCR line context' do
    ledger = build
    changed = base_snapshot
    changed['lines'][1] = 'CHANGED-1'
    changed['case_preserved_lines'][1] = 'CHANGED-1'

    expect(described_class.from_snapshot(ledger, ocr_snapshot: changed)).to be_nil
  end

  it 'rejects source lines that were truncated while the OCR snapshot was built' do
    source = base_snapshot
    stored = source.deep_dup
    source['lines'][1] = 'x' * 101
    source['case_preserved_lines'][1] = 'x' * 101
    stored['lines'][1] = 'x' * 100
    stored['case_preserved_lines'][1] = 'x' * 100

    result = described_class.build(
      options: [ first_option ],
      ocr_snapshot: stored,
      source_lines: source.fetch('lines'),
      source_case_preserved_lines: source.fetch('case_preserved_lines')
    )

    expect(result).to be_nil
  end

  it 'reads only bounded required snapshot keys without recursively normalizing unrelated data' do
    cyclic = base_snapshot
    cyclic['unused'] = cyclic
    colliding = base_snapshot.merge(lines: [ 'COLLISION' ])
    oversized = base_snapshot.merge(
      (1..30).to_h { |index| [ "unused_#{index}", index ] }
    )

    aggregate_failures do
      expect(build(ocr_snapshot: cyclic)).to be_present
      expect(build(ocr_snapshot: colliding)).to be_nil
      expect(build(ocr_snapshot: oversized)).to be_nil
    end
  end

  it 'recomputes candidate and handle identities from the canonical structural evidence' do
    stale_candidate = first_option
    stale_candidate[:candidate_id] = "azure_line_group_evidence_v1_#{'0' * 64}"
    stale_handle = first_option
    stale_handle[:handles][1][:handle_id] = "reference_pricing_handle_v1_#{'0' * 64}"
    changed_span = first_option
    changed_span[:handles][1][:provider_span_start] += 1
    changed_span[:handles][1][:provider_span_end] += 1

    expect([
      build([ stale_candidate ]),
      build([ stale_handle ]),
      build([ changed_span ])
    ]).to all(be_nil)
  end

  it 'accepts the complete configured option bound without truncation' do
    options = [ first_option ] + (1...described_class::MAX_OPTIONS).map { |ordinal| shifted_option(ordinal) }
    ledger = build(options, ocr_snapshot: base_snapshot(line_count: 34))

    aggregate_failures do
      expect(ledger.fetch('option_count')).to eq(16)
      expect(ledger.fetch('handle_count')).to eq(80)
      expect(JSON.generate(ledger).bytesize).to be <= described_class::MAX_SERIALIZED_BYTES
    end
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
    too_many = [ first_option ] +
      (1..described_class::MAX_OPTIONS).map { |ordinal| shifted_option(ordinal) }
    large_context = base_snapshot(line_count: 36)

    stub_const("#{described_class}::MAX_SERIALIZED_BYTES", 100)

    aggregate_failures do
      expect(build(too_many, ocr_snapshot: large_context)).to be_nil
      expect(build).to be_nil
    end
  end

  it 'fails closed for empty, malformed, invalid-encoding, and control-character payloads' do
    invalid_utf8 = first_option
    invalid_utf8[:candidate_id] = "bad\xFF".force_encoding(Encoding::UTF_8)
    control = first_option
    control[:candidate_id] = "bad\0identity"

    expect([
      described_class.build(
        options: [],
        ocr_snapshot: base_snapshot,
        source_lines: base_snapshot.fetch('lines'),
        source_case_preserved_lines: base_snapshot.fetch('case_preserved_lines')
      ),
      described_class.build(
        options: {},
        ocr_snapshot: base_snapshot,
        source_lines: base_snapshot.fetch('lines'),
        source_case_preserved_lines: base_snapshot.fetch('case_preserved_lines')
      ),
      described_class.build(
        options: [ nil ],
        ocr_snapshot: base_snapshot,
        source_lines: base_snapshot.fetch('lines'),
        source_case_preserved_lines: base_snapshot.fetch('case_preserved_lines')
      ),
      build([ invalid_utf8 ]),
      build([ control ])
    ]).to all(be_nil)
  end
end
