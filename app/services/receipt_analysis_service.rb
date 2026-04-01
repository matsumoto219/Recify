class ReceiptAnalysisService
  class AnalysisError < StandardError
    attr_reader :error_code

    def initialize(error_code, message)
      @error_code = error_code
      super(message)
    end
  end

  def self.call(receipt)
    ocr_result = ReceiptOcrService.call(receipt.image)

    begin
      ReceiptAiEnrichmentService.call(ocr_result)
    rescue ReceiptAiEnrichmentService::AiEnrichmentError
      build_fallback_result(ocr_result)
    end
  rescue ReceiptOcrService::OcrError => e
    raise AnalysisError.new(e.error_code, e.message)
  rescue StandardError => e
    raise AnalysisError.new("unexpected_error", e.message)
  end

  def self.build_fallback_result(ocr_result)
    raw_lines = ocr_result[:raw_lines] || []

    {
      store_name: raw_lines.first,
      purchased_at: Time.current, # 仮実装 OCRから日付抽出に置き換え予定
      total_amount: extract_total_amount(raw_lines),
      payment_method: detect_payment_method(raw_lines),
      status: "review_needed",
      items: build_fallback_items(raw_lines)
    }
  end

  def self.extract_total_amount(lines)
    total_line = lines.find { |l| l.include?("合計") }
    return nil unless total_line

    total_line.scan(/\d+/).join.to_i
  end

  def self.build_fallback_items(lines)
    item_lines = lines.select { |line| item_line?(line) }

    item_lines.each_with_index.map do |line, index|
      {
        raw_text: line,
        suggested_name: extract_item_name(line),
        confirmed_name: extract_item_name(line),
        category: detect_category(line),
        price: extract_item_price(line),
        quantity: extract_item_quantity(line),
        line_total: extract_item_line_total(line),
        needs_review: true,
        position_index: index + 1,
        confidence: 0.3
      }
    end
  end

  def self.item_line?(line)
    return false if line.blank?
    return false if line.include?("合計")
    return false if line.match?(/Master|VISA|JCB|現金/i)
    return false if line.match?(%r{\d{4}/\d{2}/\d{2}})

    line.match?(/\d/)
  end

  def self.extract_item_name(line)
    line.sub(/\s+\d.*$/, "").strip
  end

  def self.extract_item_price(line)
    numbers = line.scan(/\d+/)
    return nil if numbers.empty?

    numbers.first.to_i
  end

  def self.extract_item_quantity(line)
    quantity_match = line.match(/[x×](\d+)/i)
    return quantity_match[1].to_i if quantity_match

    1
  end

  def self.extract_item_line_total(line)
    price = extract_item_price(line)
    quantity = extract_item_quantity(line)
    return nil unless price

    price * quantity
  end

  def self.detect_category(line)
    text = line.downcase

    return "drink" if text.match?(/ｺｰﾋｰ|コーヒー|お茶|tea|coffee/)
    return "food" if text.match?(/ｻﾝﾄﾞ|サンド|パン|弁当|おにぎり/)

    "other"
  end

  def self.detect_payment_method(lines)
    text = lines.join

    return "credit_card" if text.match?(/Master|VISA|JCB/i)
    return "cash" if text.match?(/現金/)

    "other"
  end
end
