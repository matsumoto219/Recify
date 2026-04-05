class Ocr::ResponseParser
  def initialize(response:, provider: nil)
    @response = response
    @provider = provider
  end

  def call
    parsed_response = normalize_response(@response)
    raw_text = extract_raw_text(parsed_response)
    normalized_raw_text = normalize_text(raw_text)
    normalized_lines = extract_lines(parsed_response).map { |line| normalize_text(line) }.reject(&:empty?)

    {
      success: normalized_raw_text.present? || normalized_lines.any?,
      raw_text: normalized_raw_text,
      lines: normalized_lines,
      candidates: {
        store_name: extract_store_name(normalized_lines),
        purchased_at_text: extract_purchased_at_text(normalized_lines),
        total_amount: extract_total_amount(normalized_lines),
        payment_method_text: extract_payment_method_text(normalized_raw_text, normalized_lines)
      },
      error_code: nil,
      meta: {
        provider: @provider
      }
    }
  rescue JSON::ParserError, TypeError
    build_error_result("ocr_api_error")
  rescue StandardError
    build_error_result("unexpected_error")
  end

  private

  attr_reader :response, :provider

  def normalize_response(value)
    case value
    when String
      JSON.parse(value)
    when Hash
      value.deep_stringify_keys
    else
      {}
    end
  end

  def extract_raw_text(parsed_response)
    parsed_response["raw_text"] ||
      parsed_response.dig("text") ||
      parsed_response.dig("full_text") ||
      parsed_response.dig("result", "text") ||
      extract_lines(parsed_response).join("\n")
  end

  def extract_lines(parsed_response)
    explicit_lines = parsed_response["lines"] || parsed_response.dig("result", "lines")
    return explicit_lines if explicit_lines.is_a?(Array)

    raw_text = parsed_response["raw_text"] || parsed_response["text"] || parsed_response["full_text"]
    return [] if raw_text.blank?

    raw_text.to_s.lines.map(&:chomp)
  end

  def normalize_text(text)
    text.to_s
      .unicode_normalize(:nfkc)
      .downcase
      .gsub(/[[:space:]]+/, " ")
      .strip
  end

  def extract_store_name(lines)
    lines.find(&:present?)
  end

  def extract_purchased_at_text(lines)
    lines.find do |line|
      line.match?(/\d{4}[\/\-年]\d{1,2}[\/\-月]\d{1,2}日?(\s+\d{1,2}:\d{2})?/) ||
        line.match?(/\d{1,2}[\/\-]\d{1,2}[\/\-]\d{1,2,4}(\s+\d{1,2}:\d{2})?/) ||
        line.match?(/\d{1,2}:\d{2}/)
    end
  end

  def extract_total_amount(lines)
    amount_candidates = lines.filter_map do |line|
      next unless line.match?(/合計|total|税込|現計/i)

      digits = line.scan(/\d[\d,]*/).map { |value| value.delete(",\n").to_i }
      digits.max if digits.any?
    end

    amount_candidates.max
  end

  def extract_payment_method_text(raw_text, lines)
    text_candidates = [ raw_text, *lines ].compact

    text_candidates.find do |text|
      text.match?(/現金|cash|visa|master|mastercard|jcb|amex|american express|suica|pasmo|icoca|waon|nanaco|edy|id|quickpay|quicpay|paypay|楽天ペイ|rakuten pay|d払い|au pay|メルペイ|line pay|デビット|debit/i)
    end
  end

  def build_error_result(error_code)
    {
      success: false,
      raw_text: "",
      lines: [],
      candidates: {
        store_name: nil,
        purchased_at_text: nil,
        total_amount: nil,
        payment_method_text: nil
      },
      error_code: error_code,
      meta: {
        provider: @provider
      }
    }
  end
end
