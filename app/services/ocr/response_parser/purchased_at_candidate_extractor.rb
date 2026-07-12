class Ocr::ResponseParser::PurchasedAtCandidateExtractor
  PURCHASED_AT_NEARBY_TIME_OFFSETS = [ 1, -1, 2, -2 ].freeze
  PURCHASED_AT_TIME_PATTERN = /(?<!\d)(\d{1,2})\s*[:：]\s*(\d{2})(?!\d)/.freeze

  def self.call(fields:, lines:, profile:)
    new(fields:, lines:, profile:).call
  end

  def initialize(fields:, lines:, profile:)
    @fields = fields
    @lines = lines
    @profile = profile
  end

  def call
    normalize_purchased_at_text(extract_purchased_at_text)
  end

  private

  attr_reader :fields, :lines, :profile

  def extract_purchased_at_text
    date = fields.dig("TransactionDate", "valueDate")
    time = fields.dig("TransactionTime", "valueTime")
    return [ date, time ].compact.join(" ") if date.present? || time.present?

    extract_purchased_at_text_from_lines(lines)
  end

  def extract_purchased_at_text_from_lines(lines)
    normalized_lines = Array(lines)
    date_entry = normalized_lines.each_with_index.filter_map do |line, index|
      date_text = extract_purchased_at_date_text(line)
      { date_text: date_text, line: line, index: index } if date_text.present?
    end.first

    if date_entry.present?
      time_text = extract_purchased_at_time_text(date_entry[:line]) ||
        nearby_purchased_at_time_text(normalized_lines, date_entry[:index])
      return [ date_entry[:date_text], time_text ].compact.join(" ")
    end

    normalized_lines.lazy.filter_map { |line| extract_purchased_at_time_text(line) }.first
  end

  def extract_purchased_at_date_text(line)
    text = line.to_s
    pattern = profile.ocr_purchased_at_date_patterns.find { |candidate| text.match?(candidate) }
    return if pattern.blank?

    text.match(pattern).to_s.gsub(/[[:space:]　]+/, "")
  end

  def nearby_purchased_at_time_text(lines, date_index)
    PURCHASED_AT_NEARBY_TIME_OFFSETS.each do |offset|
      index = date_index + offset
      next if index.negative? || index >= lines.size

      time_text = extract_purchased_at_time_text(lines[index])
      return time_text if time_text.present?
    end

    nil
  end

  def extract_purchased_at_time_text(line)
    match = line.to_s.match(PURCHASED_AT_TIME_PATTERN)
    return if match.blank?

    hour = match[1].to_i
    minute = match[2].to_i
    return if hour > 23 || minute > 59

    "#{match[1]}:#{match[2]}"
  end

  def normalize_purchased_at_text(text)
    return nil if text.blank?

    text.to_s.gsub("/", "-")
  end
end
