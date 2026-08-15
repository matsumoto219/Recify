# frozen_string_literal: true

require 'base64'
require 'open3'
require 'rails_helper'

RSpec.describe 'ReceiptAmountService reference pricing numeric properties' do
  FIXED_SEED = 0x1A2B_3C4D
  RANDOM_VECTOR_COUNT = 64
  INDEPENDENT_LINE_TOTAL_MAX = 999_999_999
  INDEPENDENT_UNIT_SCALES = {
    'each' => Rational(1),
    'item' => Rational(1),
    'piece' => Rational(1),
    'bag' => Rational(1),
    'sheet' => Rational(1),
    'unit' => Rational(1),
    'box' => Rational(1),
    'set' => Rational(1),
    'gram' => Rational(1),
    'kilogram' => Rational(1_000),
    'milligram' => Rational(1, 1_000),
    'liter' => Rational(1_000),
    'milliliter' => Rational(1),
    'cubic_centimeter' => Rational(1)
  }.freeze
  INDEPENDENT_UNIT_GROUPS = [
    %w[gram kilogram milligram].freeze,
    %w[liter milliliter cubic_centimeter].freeze,
    *%w[each item piece bag sheet unit box set].map { |code| [ code ].freeze }
  ].freeze

  def decimal_text(units, scale)
    digits = units.to_s.rjust(scale + 1, '0')
    return digits if scale.zero?

    "#{digits[0...-scale]}.#{digits[-scale..]}"
  end

  def independent_projection(vector)
    price = Rational(vector.fetch('reference_price_amount'))
    purchased = Rational(vector.fetch('purchased_quantity')) *
      INDEPENDENT_UNIT_SCALES.fetch(vector.fetch('purchased_unit_code'))
    reference = Rational(vector.fetch('reference_quantity')) *
      INDEPENDENT_UNIT_SCALES.fetch(vector.fetch('reference_unit_code'))
    exact = price * purchased / reference
    integer, remainder = exact.numerator.divmod(exact.denominator)

    {
      'exactNumerator' => exact.numerator.to_s,
      'exactDenominator' => exact.denominator.to_s,
      'projectedAmount' => integer + (remainder * 2 >= exact.denominator ? 1 : 0)
    }
  end

  def fixed_vectors
    unit_coverage = INDEPENDENT_UNIT_SCALES.keys.map do |code|
      {
        'id' => "unit_#{code}",
        'reference_price_amount' => '17.5',
        'reference_quantity' => '2',
        'reference_unit_code' => code,
        'purchased_quantity' => '3',
        'purchased_unit_code' => code
      }
    end

    boundaries = [
      [ 'half_up_before', '0.999998', '2', 'gram', '1', 'gram' ],
      [ 'half_up_tie', '1', '2', 'gram', '1', 'gram' ],
      [ 'half_up_after', '1.000002', '2', 'gram', '1', 'gram' ],
      [ 'maximum_price', '999999999999', '9999.999', 'gram', '9999.999', 'gram' ],
      [ 'small_exact', '0.000001', '9999.999', 'gram', '0.001', 'gram' ],
      [ 'mass_gram', '333.333333', '1', 'gram', '7', 'gram' ],
      [ 'mass_kilogram', '333.333333', '1', 'gram', '0.007', 'kilogram' ],
      [ 'mass_milligram', '333.333333', '1', 'gram', '7000', 'milligram' ],
      [ 'volume_milliliter', '123.456789', '1', 'milliliter', '9', 'milliliter' ],
      [ 'volume_liter', '123.456789', '1', 'milliliter', '0.009', 'liter' ],
      [ 'volume_cc', '123.456789', '1', 'milliliter', '9', 'cubic_centimeter' ],
      [ 'basis_base', '17.5', '25', 'gram', '7.125', 'gram' ],
      [ 'basis_scaled', '70', '100', 'gram', '7.125', 'gram' ],
      [ 'monotonic_low', '498.125001', '100', 'gram', '342.001', 'gram' ],
      [ 'monotonic_high', '498.125001', '100', 'gram', '342.002', 'gram' ],
      [ 'cross_scale_large', '0.000001', '0.001', 'milligram', '9.999', 'kilogram' ]
    ].map do |id, price, reference_quantity, reference_unit, purchased_quantity, purchased_unit|
      {
        'id' => id,
        'reference_price_amount' => price,
        'reference_quantity' => reference_quantity,
        'reference_unit_code' => reference_unit,
        'purchased_quantity' => purchased_quantity,
        'purchased_unit_code' => purchased_unit
      }
    end

    unit_coverage + boundaries
  end

  def seeded_vectors
    random = Random.new(FIXED_SEED)
    vectors = []
    attempts = 0

    while vectors.size < RANDOM_VECTOR_COUNT && attempts < 10_000
      attempts += 1
      group = INDEPENDENT_UNIT_GROUPS.fetch(random.rand(INDEPENDENT_UNIT_GROUPS.size))
      reference_unit = group.fetch(random.rand(group.size))
      purchased_unit = group.fetch(random.rand(group.size))
      countable = group.one? && !%w[gram kilogram milligram liter milliliter cubic_centimeter].include?(group.first)
      reference_quantity = if countable
        random.rand(1..9_999).to_s
      else
        decimal_text(random.rand(1..9_999_999), 3)
      end
      purchased_quantity = if countable
        random.rand(1..9_999).to_s
      else
        decimal_text(random.rand(1..9_999_999), 3)
      end
      price_scale = random.rand(0..6)
      vector = {
        'id' => "seed_#{vectors.size}",
        'reference_price_amount' => decimal_text(random.rand(0..999_999_999), price_scale),
        'reference_quantity' => reference_quantity,
        'reference_unit_code' => reference_unit,
        'purchased_quantity' => purchased_quantity,
        'purchased_unit_code' => purchased_unit
      }
      next if independent_projection(vector).fetch('projectedAmount') > INDEPENDENT_LINE_TOTAL_MAX

      vectors << vector
    end

    raise "fixed seed generated only #{vectors.size} bounded vectors" unless vectors.size == RANDOM_VECTOR_COUNT

    vectors
  end

  def measurement_vectors
    fixed_vectors + seeded_vectors
  end

  def ruby_projection(vector)
    result = ReceiptAmountService.reference_item_extension_projection(
      reference_price_amount: vector.fetch('reference_price_amount'),
      reference_quantity: vector.fetch('reference_quantity'),
      reference_unit_code: vector.fetch('reference_unit_code'),
      purchased_quantity: vector.fetch('purchased_quantity'),
      purchased_unit_code: vector.fetch('purchased_unit_code')
    )

    {
      'exactNumerator' => result.fetch(:exact_amount).numerator.to_s,
      'exactDenominator' => result.fetch(:exact_amount).denominator.to_s,
      'projectedAmount' => result.fetch(:projected_amount)
    }
  end

  def javascript_projections(vectors)
    source = Rails.root.join('app/javascript/receipts/amount_preview.js').read.gsub(/^export /, '')
    contract = ReceiptFormPresenter.new(receipt: build(:receipt)).reference_pricing_contract_value
    encoded_source = Base64.strict_encode64(source)
    encoded_contract = Base64.strict_encode64(contract.to_json)
    encoded_vectors = Base64.strict_encode64(vectors.to_json)
    script = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
      const referencePricingContract = JSON.parse(
        Buffer.from(#{encoded_contract.inspect}, 'base64').toString('utf8')
      )
      const vectors = JSON.parse(Buffer.from(#{encoded_vectors.inspect}, 'base64').toString('utf8'))
      const runner = `
        const calculate = (vector) => referenceItemExtension({
          referencePricingContract,
          referencePriceAmount: vector.reference_price_amount,
          referenceQuantity: vector.reference_quantity,
          referenceUnitCode: vector.reference_unit_code,
          purchasedQuantity: vector.purchased_quantity,
          purchasedUnitCode: vector.purchased_unit_code
        })
        const results = vectors.map((vector) => {
          const before = JSON.stringify(vector)
          const first = calculate(vector)
          const second = calculate(vector)
          return { before, after: JSON.stringify(vector), first, second }
        })
        process.stdout.write(JSON.stringify(results))
      `
      eval(source + '\\n' + runner)
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3('node', '-e', script)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

  def capture_sql
    queries = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name].to_s)

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { yield }
    queries
  end

  it 'matches one independent exact oracle in Ruby and JavaScript for fixed-seed bounded vectors' do
    vectors = measurement_vectors
    original = Marshal.load(Marshal.dump(vectors))
    ruby_first = nil
    ruby_second = nil
    javascript = nil

    expect(Ocr::Client).not_to receive(:new)
    expect(Ai::Client).not_to receive(:new)
    expect(ReceiptOcrService).not_to receive(:call)
    expect(ReceiptAiEnrichmentService).not_to receive(:call)

    sql = capture_sql do
      ruby_first = vectors.map { |vector| ruby_projection(vector) }
      ruby_second = vectors.map { |vector| ruby_projection(vector) }
      javascript = javascript_projections(vectors)
    end
    expected = vectors.map { |vector| independent_projection(vector) }

    aggregate_failures do
      vectors.each_with_index do |vector, index|
        expect(ruby_first.fetch(index)).to eq(expected.fetch(index)), vector.fetch('id')
        expect(ruby_second.fetch(index)).to eq(expected.fetch(index)), vector.fetch('id')
        expect(javascript.fetch(index).fetch('first')).to eq(expected.fetch(index)), vector.fetch('id')
        expect(javascript.fetch(index).fetch('second')).to eq(expected.fetch(index)), vector.fetch('id')
        expect(javascript.fetch(index).fetch('after')).to eq(javascript.fetch(index).fetch('before')), vector.fetch('id')
      end

      expect(vectors).to eq(original)
      expect(sql).to eq([])
    end
  end

  it 'preserves unit representation, proportional basis, and monotonic exact extension properties' do
    projections = measurement_vectors.to_h do |vector|
      [ vector.fetch('id'), ruby_projection(vector) ]
    end

    aggregate_failures do
      expect(projections.values_at('mass_gram', 'mass_kilogram', 'mass_milligram').uniq.size).to eq(1)
      expect(projections.values_at('volume_milliliter', 'volume_liter', 'volume_cc').uniq.size).to eq(1)
      expect(projections.fetch('basis_scaled')).to eq(projections.fetch('basis_base'))
      expect(projections.dig('monotonic_high', 'exactNumerator').to_i *
        projections.dig('monotonic_low', 'exactDenominator').to_i).to be >=
          (projections.dig('monotonic_low', 'exactNumerator').to_i *
            projections.dig('monotonic_high', 'exactDenominator').to_i)
    end
  end

  it 'rejects oversized or non-Q2-decimal representations at the public projection boundary' do
    huge_rational = Rational(1, 2**10_000)
    huge_big_decimal = BigDecimal('9' * 10_000)
    malicious = [
      { reference_price_amount: nil },
      { reference_price_amount: '' },
      { reference_price_amount: [] },
      { reference_price_amount: {} },
      { reference_price_amount: '1e3' },
      { reference_price_amount: '-1' },
      { reference_price_amount: BigDecimal('NaN') },
      { reference_price_amount: BigDecimal('Infinity') },
      { reference_price_amount: '9' * 100_000 },
      { reference_price_amount: huge_rational },
      { reference_price_amount: 2**10_000 },
      { reference_price_amount: BigDecimal('1E100000') },
      { reference_price_amount: huge_big_decimal },
      { reference_price_amount: Rational(1, 3) },
      { reference_price_amount: '0.0000001' },
      { reference_price_amount: '999999999999.000001' },
      { reference_quantity: nil },
      { reference_quantity: '' },
      { reference_quantity: [] },
      { reference_quantity: {} },
      { reference_quantity: '1e3' },
      { reference_quantity: '-0' },
      { reference_quantity: '0' },
      { reference_quantity: '-1' },
      { reference_quantity: '9' * 100_000 },
      { purchased_quantity: nil },
      { purchased_quantity: '' },
      { purchased_quantity: [] },
      { purchased_quantity: {} },
      { purchased_quantity: '1e3' },
      { purchased_quantity: '-0' },
      { purchased_quantity: '0' },
      { purchased_quantity: '-1' },
      { purchased_quantity: '9' * 100_000 }
    ]
    defaults = {
      reference_price_amount: '120',
      reference_quantity: '500',
      reference_unit_code: 'milliliter',
      purchased_quantity: '1.5',
      purchased_unit_code: 'liter'
    }
    malicious_snapshot = lambda do
      malicious.map do |entry|
        entry.map { |key, value| [ key, value.class.name, value.inspect ] }
      end
    end
    original = malicious_snapshot.call
    errors = []
    main_path_errors = []
    split_calls = 0
    split_trace = TracePoint.new(:call, :c_call) do |event|
      split_calls += 1 if event.self.equal?(huge_big_decimal) && event.method_id == :split
    end
    accepted_finite_rational = nil
    accepted_negative_zero = nil
    oversized_string_class = Class.new(String) do
      def valid_encoding?
        raise 'valid_encoding? must not inspect an oversized decimal'
      end
    end
    oversized_string = oversized_string_class.new('9' * (Amounts::ExactBoundedDecimal::MAX_INPUT_BYTES + 1))
    main_path_item = {
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: '120',
      reference_quantity: '500',
      reference_quantity_unit_code: 'milliliter',
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: 'gross',
      quantity: '1.5',
      quantity_unit_code: 'liter',
      quantity_unit_raw: nil,
      tax_rate: BigDecimal('0')
    }

    expect(Ocr::Client).not_to receive(:new)
    expect(Ai::Client).not_to receive(:new)
    expect(ReceiptOcrService).not_to receive(:call)
    expect(ReceiptAiEnrichmentService).not_to receive(:call)

    sql = capture_sql do
      split_trace.enable do
        Timeout.timeout(2) do
        malicious.each do |override|
          ReceiptAmountService.reference_item_extension_projection(**defaults.merge(override))
        rescue ReceiptAmountService::InvalidItemSourceError => error
          errors << error
        end
        malicious.each do |override|
          main_override = override.transform_keys do |attribute|
            attribute == :purchased_quantity ? :quantity : attribute
          end
          ReceiptAmountService.call(
            receipt: {},
            receipt_items: [ main_path_item.merge(main_override) ],
            receipt_tax_details: [],
            context: :edit_save
          )
        rescue ReceiptAmountService::InvalidItemSourceError => error
          main_path_errors << error
        end
          accepted_finite_rational = ReceiptAmountService.reference_item_extension_projection(
            reference_price_amount: Rational(1, 1_000_000),
            reference_quantity: 1,
            reference_unit_code: 'gram',
            purchased_quantity: 1,
            purchased_unit_code: 'gram'
          )
          accepted_negative_zero = ReceiptAmountService.reference_item_extension_projection(
            reference_price_amount: '-0',
            reference_quantity: 1,
            reference_unit_code: 'gram',
            purchased_quantity: 1,
            purchased_unit_code: 'gram'
          )
          expect do
            ReceiptAmountService.reference_item_extension_projection(
              **defaults.merge(reference_price_amount: oversized_string)
            )
          end.to raise_error(
            ReceiptAmountService::InvalidItemSourceError,
            'Invalid item pricing source'
          )
        end
      end
    end

    aggregate_failures do
      expect(errors.size).to eq(malicious.size)
      expect(errors).to all(have_attributes(message: 'Invalid item pricing source'))
      expect(main_path_errors.size).to eq(malicious.size)
      expect(main_path_errors).to all(have_attributes(message: 'Invalid item pricing source'))
      expect(accepted_finite_rational).to eq(
        exact_amount: Rational(1, 1_000_000),
        projected_amount: 0
      )
      expect(accepted_negative_zero).to eq(exact_amount: Rational(0), projected_amount: 0)
      expect(malicious_snapshot.call).to eq(original)
      expect(split_calls).to eq(0)
      expect(sql).to eq([])
    end
  end
end
