require 'rails_helper'
require 'timeout'

RSpec.describe 'ReceiptAmountService Measurement properties' do
  def reference_item(overrides = {})
    {
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: BigDecimal('120'),
      reference_quantity: BigDecimal('500'),
      reference_quantity_unit_code: 'milliliter',
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: 'gross',
      quantity: BigDecimal('1.5'),
      quantity_unit_code: 'liter',
      quantity_unit_raw: nil,
      price: 999,
      original_line_total: 998,
      line_total: 997,
      tax_rate: BigDecimal('0')
    }.merge(overrides)
  end

  def explicit_item(overrides = {})
    {
      pricing_source_kind: 'explicit_line_total',
      quantity: BigDecimal('2'),
      quantity_unit_code: 'kilogram',
      original_line_total: 77,
      line_total: 77,
      tax_rate: BigDecimal('0')
    }.merge(overrides)
  end

  def count_item(overrides = {})
    {
      pricing_source_kind: 'count_unit_price',
      price: 50,
      quantity: 2,
      quantity_unit_code: 'each',
      original_line_total: 9_999,
      line_total: 9_999,
      tax_rate: BigDecimal('0')
    }.merge(overrides)
  end

  def calculate(items, context: :edit_save)
    ReceiptAmountService.call(
      receipt: {},
      receipt_items: items,
      receipt_tax_details: [],
      context: context
    )
  end

  def source_fingerprint(item)
    item.slice(
      :pricing_source_kind,
      :reference_price_amount,
      :reference_quantity,
      :reference_quantity_unit_code,
      :reference_price_tax_inclusion,
      :quantity,
      :quantity_unit_code,
      :original_line_total,
      :line_total
    )
  end

  it 'keeps receipt amounts and per-row authorities invariant under item permutation' do
    items = [ reference_item, explicit_item, count_item ]

    results = items.permutation.map { |permutation| calculate(permutation) }
    canonical_sources = results.first.dig(:computed, :source_items).map { |item| source_fingerprint(item) }
      .sort_by { |item| [ item.fetch(:pricing_source_kind).to_s, item.fetch(:line_total) ] }

    aggregate_failures do
      expect(results.map { |result| result.dig(:resolved, :total) }.uniq).to eq([ 537 ])
      expect(results.map { |result| result.dig(:resolved, :subtotal) }.uniq).to eq([ 537 ])

      results.each do |result|
        sources = result.dig(:computed, :source_items).map { |item| source_fingerprint(item) }
          .sort_by { |item| [ item.fetch(:pricing_source_kind).to_s, item.fetch(:line_total) ] }

        expect(sources).to eq(canonical_sources)
      end
    end
  end

  it 'changes only the selected row and returns exactly to its source after quantity A-B-A' do
    first = reference_item(reference_price_amount: BigDecimal('120'))
    second = reference_item(
      reference_price_amount: BigDecimal('498'),
      reference_quantity: BigDecimal('100'),
      reference_quantity_unit_code: 'gram',
      quantity: BigDecimal('342'),
      quantity_unit_code: 'gram'
    )

    baseline = calculate([ first, second ]).dig(:computed, :source_items)
    changed = calculate([ first.merge(quantity: BigDecimal('2')), second ]).dig(:computed, :source_items)
    restored = calculate([ first, second ]).dig(:computed, :source_items)

    aggregate_failures do
      expect(changed.first[:line_total]).not_to eq(baseline.first[:line_total])
      expect(source_fingerprint(changed.second)).to eq(source_fingerprint(baseline.second))
      expect(restored.map { |item| source_fingerprint(item) })
        .to eq(baseline.map { |item| source_fingerprint(item) })
    end
  end

  it 'processes the bounded item set in memory without per-item SQL or provider calls' do
    items = Array.new(100) { reference_item(reference_price_amount: BigDecimal('0')) }
    extension_calls = 0
    capture_sql = lambda do |&block|
      queries = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] unless payload[:name] == 'SCHEMA'
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &block)
      queries
    end

    expect(ReceiptOcrService).not_to receive(:call)
    expect(ReceiptAiEnrichmentService).not_to receive(:call)
    allow(Amounts::ReferenceItemExtension).to receive(:call).and_wrap_original do |method, **attributes|
      extension_calls += 1
      method.call(**attributes)
    end

    one_item_sql = capture_sql.call { calculate(items.first(1)) }
    extension_calls = 0
    result = nil
    bounded_set_sql = capture_sql.call { Timeout.timeout(2) { result = calculate(items) } }

    aggregate_failures do
      expect(bounded_set_sql.size).to eq(one_item_sql.size)
      expect(bounded_set_sql.size).to be <= 1
      expect(result.dig(:computed, :source_items).size).to eq(100)
      expect(result.dig(:resolved, :total)).to eq(0)
      expect(extension_calls).to be <= items.size * 4
    end
  end

  it 'keeps explicit authority bounded when unused reference diagnostics are oversized' do
    oversized = '9' * 500_000
    item = explicit_item(
      reference_price_amount: oversized,
      reference_quantity: '1',
      reference_quantity_unit_code: 'gram',
      reference_price_tax_inclusion: 'gross',
      quantity_unit_code: 'gram'
    )
    original = item.deep_dup
    result = nil

    expect {
      Timeout.timeout(1) { result = calculate([ item ]) }
    }.not_to raise_error

    aggregate_failures do
      expect(result.dig(:computed, :source_items, 0, :pricing_source_kind)).to eq('explicit_line_total')
      expect(result.dig(:computed, :source_items, 0, :line_total)).to eq(77)
      expect(item).to eq(original)
    end
  end

  it 'rejects malformed item numeric strings before unbounded normalization' do
    oversized_string_class = Class.new(String) do
      def valid_encoding?
        raise 'valid_encoding? must not inspect an oversized numeric source'
      end
    end
    oversized = oversized_string_class.new("sensitive#{'9' * 500_000}")
    invalid_utf8 = "sensitive\xFF".b.force_encoding(Encoding::UTF_8)
    hostile_scalar = Class.new do
      def to_s
        raise 'unsupported numeric source must not be stringified'
      end
    end.new
    unclassified_item = lambda do |quantity|
      {
        pricing_source_kind: nil,
        quantity: quantity,
        quantity_unit_code: 'gram',
        original_line_total: 77,
        line_total: 77,
        tax_rate: BigDecimal('0')
      }
    end
    stale_attributes = %i[
      price
      original_line_total
      line_total
      discount_amount
      discount_rate
      tax_rate
      amount_persisted_original_line_total
      amount_persisted_discount_amount
      amount_persisted_discount_rate
      amount_persisted_line_total
    ]
    items_and_attributes = [
      [ unclassified_item.call(oversized), :quantity ],
      *stale_attributes.map { |attribute| [ reference_item(attribute => oversized), attribute ] },
      [ unclassified_item.call(invalid_utf8), :quantity ],
      *[
        [ 2, 5 ],
        { amount: 1 },
        Rational(1, 2),
        2**10_000,
        BigDecimal('9' * 10_000),
        BigDecimal('NaN'),
        BigDecimal('Infinity'),
        Float::NAN,
        Float::INFINITY,
        1e100,
        hostile_scalar
      ].map { |source| [ unclassified_item.call(source), :quantity ] }
    ]
    original_source_ids = items_and_attributes.map { |item, attribute| item.fetch(attribute).object_id }
    errors = []

    expect {
      Timeout.timeout(1) do
        items_and_attributes.each do |item, _attribute|
          calculate([ item ], context: :analysis)
        rescue ReceiptAmountService::InvalidItemSourceError => error
          errors << error
        end
      end
    }.not_to raise_error

    aggregate_failures do
      expect(errors.size).to eq(items_and_attributes.size)
      expect(errors).to all(have_attributes(message: 'Invalid item pricing source'))
      expect(errors.map(&:message).join).not_to include('sensitive')
      expect(items_and_attributes.map { |item, attribute| item.fetch(attribute).object_id }).to eq(original_source_ids)
    end

    rational_result = calculate([ reference_item(quantity: Rational(3, 2)) ])
    expect(rational_result.dig(:computed, :source_items, 0, :line_total)).to eq(360)
  end

  it 'returns existing parser defaults before normalizing oversized or invalid-encoding strings' do
    oversized_string_class = Class.new(String) do
      def valid_encoding?
        raise 'valid_encoding? must not inspect an oversized numeric source'
      end
    end
    oversized = oversized_string_class.new("sensitive#{'9' * 500_000}")
    invalid_utf8 = "sensitive\xFF".b.force_encoding(Encoding::UTF_8)
    hostile_scalar = Class.new do
      def to_s
        raise 'unsupported numeric source must not be stringified'
      end
    end.new
    sources = [
      oversized,
      invalid_utf8,
      [ 2, 5 ],
      { amount: 1 },
      Rational(1, 3),
      2**10_000,
      BigDecimal('9' * 10_000),
      BigDecimal('NaN'),
      BigDecimal('Infinity'),
      Float::NAN,
      Float::INFINITY,
      1e100,
      hostile_scalar
    ]
    source_ids = sources.map(&:object_id)
    results = nil

    expect {
      Timeout.timeout(1) do
        results = sources.map do |source|
          [
            ReceiptAmountService.parse_amount(source, default: 7),
            ReceiptAmountService.parse_amount_or_nil(source),
            ReceiptAmountService.parse_quantity(source, default: BigDecimal('1'))
          ]
        end
      end
    }.not_to raise_error

    aggregate_failures do
      expect(results.map do |amount, optional_amount, quantity|
        amount == 7 && optional_amount.nil? && quantity == BigDecimal('1')
      end).to all(be(true))
      expect(ReceiptAmountService.parse_amount(12)).to eq(12)
      expect(ReceiptAmountService.parse_amount(BigDecimal('12'))).to eq(12)
      expect(ReceiptAmountService.parse_quantity(1.5)).to eq(BigDecimal('1.5'))
      expect(ReceiptAmountService.parse_quantity(BigDecimal('1.5'))).to eq(BigDecimal('1.5'))
      expect(sources.map(&:object_id)).to eq(source_ids)
    end
  end
end
