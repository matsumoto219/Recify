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
        store_address: extract_store_address(parsed_response),
        store_phone_number: extract_store_phone_number(parsed_response),
        purchased_at_text: normalize_purchased_at_text(extract_purchased_at_text(normalized_lines)),
        total_amount: extract_total_amount(normalized_lines),
        subtotal_amount: extract_subtotal_amount(parsed_response, normalized_lines),
        tax_amount: extract_tax_amount(parsed_response, normalized_lines),
        tax_rate: extract_tax_rate(parsed_response),
        payment_method_text: extract_payment_method_text(normalized_raw_text, normalized_lines),
        tip_amount: extract_tip_amount(parsed_response),
        country_region: extract_country_region(parsed_response),
        receipt_type: extract_receipt_type(parsed_response),
        payments: extract_payments(parsed_response),
        tax_details: extract_tax_details(parsed_response),
        items: extract_items(parsed_response)
      },
      error_code: nil,
      meta: {
        provider: @provider
      }
    }
  rescue JSON::ParserError
    build_error_result("ocr_api_error")
  rescue TypeError
    build_error_result("unexpected_error")
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
      raise TypeError, "unsupported ocr response"
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

  def extract_store_address(parsed_response)
    parsed_response.dig("fields", "MerchantAddress", "valueString") ||
      parsed_response.dig("fields", "MerchantAddress", "content")
  rescue
    nil
  end

  def extract_store_phone_number(parsed_response)
    parsed_response.dig("fields", "MerchantPhoneNumber", "valuePhoneNumber") ||
      parsed_response.dig("fields", "MerchantPhoneNumber", "content") ||
      parsed_response.dig("fields", "MerchantPhoneNumber", "valueString")
  rescue
    nil
  end

  def extract_purchased_at_text(lines)
    lines.find do |line|
      line.match?(/\d{4}[\/\-年]\d{1,2}[\/\-月]\d{1,2}日?(\s+\d{1,2}:\d{2})?/) ||
        line.match?(/\d{1,2}[\/\-]\d{1,2}[\/\-]\d{1,2,4}(\s+\d{1,2}:\d{2})?/) ||
        line.match?(/\d{1,2}:\d{2}/)
    end
  end

  def normalize_purchased_at_text(text)
    return nil if text.blank?

    text.to_s.gsub("/", "-")
  end

  def extract_total_amount(lines)
    amount_candidates = lines.filter_map do |line|
      next unless line.match?(/合計|total|税込|現計/i)

      digits = line.scan(/\d[\d,]*/).map { |value| value.delete(",\n").to_i }
      digits.max if digits.any?
    end

    amount_candidates.max
  end

  def extract_subtotal_amount(parsed_response, lines)
    parsed_response.dig("fields", "Subtotal", "valueNumber") ||
      extract_amount_from_lines(lines, /小計|subtotal|税抜/i)
  rescue
    nil
  end

  def extract_tax_amount(parsed_response, lines)
    parsed_response.dig("fields", "TotalTax", "valueNumber") ||
      parsed_response.dig("fields", "Tax", "valueNumber") ||
      extract_amount_from_lines(lines, /消費税|税額|tax/i)
  rescue
    nil
  end

  def extract_tax_rate(parsed_response)
    details = parsed_response.dig("fields", "TaxDetails", "valueArray")
    return nil unless details.is_a?(Array)

    first_rate = details.filter_map do |detail|
      detail.dig("valueObject", "Rate", "valueNumber")
    end.first

    first_rate
  rescue
    nil
  end

  def extract_amount_from_lines(lines, pattern)
    amount_candidates = Array(lines).filter_map do |line|
      next unless line.match?(pattern)

      digits = line.scan(/\d[\d,]*/).map { |value| value.delete(",\n").to_i }
      digits.max if digits.any?
    end

    amount_candidates.max
  end

  def extract_payment_method_text(raw_text, lines)
    payment_method_pattern = /現金|cash|visa|mastercard|master|jcb|amex|american express|suica|pasmo|icoca|waon|nanaco|edy|id|quickpay|quicpay|paypay|楽天ペイ|rakuten pay|d払い|au pay|メルペイ|line pay|デビット|debit/i

    line_match = Array(lines).find do |line|
      line.match?(payment_method_pattern)
    end
    return line_match.match(payment_method_pattern)&.[](0) if line_match.present?

    raw_text.to_s.match(payment_method_pattern)&.[](0)
  end

  def extract_tip_amount(parsed_response)
    parsed_response.dig("fields", "Tip", "valueNumber")
  rescue
    nil
  end

  def extract_country_region(parsed_response)
    parsed_response.dig("fields", "CountryRegion", "valueString")
  rescue
    nil
  end

  def extract_receipt_type(parsed_response)
    parsed_response.dig("fields", "ReceiptType", "valueString")
  rescue
    nil
  end

  def extract_payments(parsed_response)
    payments = parsed_response.dig("fields", "Payments", "valueArray")
    return [] unless payments.is_a?(Array)

    payments.map do |p|
      {
        method: p.dig("valueObject", "Method", "valueString"),
        amount: p.dig("valueObject", "Amount", "valueNumber")
      }
    end
  rescue
    []
  end

  def extract_tax_details(parsed_response)
    details = parsed_response.dig("fields", "TaxDetails", "valueArray")
    return [] unless details.is_a?(Array)

    details.map do |d|
      obj = d["valueObject"] || {}
      {
        description: obj.dig("Description", "valueString"),
        amount: obj.dig("Amount", "valueNumber"),
        rate: obj.dig("Rate", "valueNumber"),
        net_amount: obj.dig("NetAmount", "valueNumber")
      }
    end
  rescue
    []
  end

  def extract_items(parsed_response)
    items = parsed_response.dig("fields", "Items", "valueArray")
    return [] unless items.is_a?(Array)

    items.map do |item|
      obj = item["valueObject"] || {}
      {
        raw_text: obj.dig("Description", "valueString") || obj.dig("Description", "content"),
        price: obj.dig("Price", "valueNumber"),
        quantity: obj.dig("Quantity", "valueNumber"),
        quantity_unit: obj.dig("QuantityUnit", "valueString"),
        product_code: obj.dig("ProductCode", "valueString"),
        line_total: obj.dig("TotalPrice", "valueNumber"),
        confidence: item["confidence"]
      }
    end
  rescue
    []
  end

  def build_error_result(error_code)
    {
      success: false,
      raw_text: "",
      lines: [],
      candidates: {
        store_name: nil,
        store_address: nil,
        store_phone_number: nil,
        purchased_at_text: nil,
        total_amount: nil,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil,
        payment_method_text: nil,
        tip_amount: nil,
        country_region: nil,
        receipt_type: nil,
        payments: [],
        tax_details: [],
        items: []
      },
      error_code: error_code,
      meta: {
        provider: @provider
      }
    }
  end
end
