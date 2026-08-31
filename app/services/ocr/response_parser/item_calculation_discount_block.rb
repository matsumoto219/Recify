class Ocr::ResponseParser::ItemCalculationDiscountBlock
  MAX_LINES = 150
  MAX_LINE_CONTENT_BYTES = 4_096
  MAX_AMOUNT = 999_999_999_999
  CONTROL_CHARACTER_PATTERN = /[\x00-\x08\x0B-\x1F]/.freeze

  def self.call(lines:, profile:)
    new(lines:, profile:).call
  end

  def initialize(lines:, profile:)
    @lines = lines
    @profile = profile
  end

  def call
    return unless lines.is_a?(Array) && lines.size <= MAX_LINES
    return unless lines.all? { |line| line.is_a?(String) && line.valid_encoding? && line.bytesize <= MAX_LINE_CONTENT_BYTES && !line.match?(CONTROL_CHARACTER_PATTERN) }

    label_count = lines.count do |line|
      profile.ocr_item_calculation_discount_line_pattern.match?(line) ||
        profile.ocr_item_calculation_discount_label_line_pattern.match?(line)
    end
    return unless label_count == 1

    matches = lines.each_index.filter_map { |index| block_at(index) }
    matches.sole if matches.one?
  rescue ArgumentError, EncodingError
    nil
  end

  private

  attr_reader :lines, :profile

  def block_at(index)
    return if profile.ocr_receipt_level_discount_line_pattern.match?(lines[index])

    single = profile.ocr_item_calculation_discount_line_pattern.match(lines[index])
    if single
      return if profile.ocr_item_calculation_discount_amount_line_pattern.match?(lines[index + 1].to_s)

      return result(single, index, single, index)
    end

    label = profile.ocr_item_calculation_discount_label_line_pattern.match(lines[index])
    return unless label

    rate_index = label.names.include?("rate") && label[:rate] ? index : index + 1
    rate = rate_index == index ? label : profile.ocr_item_calculation_discount_rate_line_pattern.match(lines[rate_index].to_s)
    return unless rate

    amount_index = rate_index + 1
    amount_index += 1 if profile.ocr_item_discount_per_unit_note_pattern.match?(lines[amount_index].to_s)
    amount = profile.ocr_item_calculation_discount_amount_line_pattern.match(lines[amount_index].to_s)
    return unless amount
    return if profile.ocr_item_calculation_discount_amount_line_pattern.match?(lines[amount_index + 1].to_s)

    result(rate, rate_index, amount, amount_index, block_start: index)
  end

  def result(rate_match, rate_index, amount_match, amount_index, block_start: rate_index)
    return if rate_match[:rate].bytesize > 64 || amount_match[:amount].bytesize > 64

    rate = BigDecimal(rate_match[:rate].unicode_normalize(:nfkc)) / 100
    amount = BigDecimal(amount_match[:amount].unicode_normalize(:nfkc).delete(","))
    return unless rate.positive? && rate < 1 && rate == rate.round(3)
    return unless amount.between?(0, MAX_AMOUNT)

    {
      rate: rate,
      amount: amount.to_i,
      block_start_line_index: block_start,
      block_end_line_index: amount_index,
      evidence: {
        rate: component(rate_match, :rate, rate_index),
        amount: component(amount_match, :amount, amount_index)
      }
    }
  end

  def component(match, key, index)
    {
      line_index: index,
      byte_offset: lines[index][0...match.begin(key)].bytesize,
      byte_length: match[key].bytesize
    }
  end
end
