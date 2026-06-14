# frozen_string_literal: true

module GeneratedReceipts
  class TextRenderer
    def self.call(case_data)
      new(case_data).call
    end

    def initialize(case_data)
      @case_data = case_data
      @expected = case_data.fetch("expected")
      @render = case_data.fetch("render", {})
    end

    def call
      return custom_lines_text if custom_lines?

      [
        header_lines,
        item_lines,
        adjustment_lines,
        total_lines,
        tax_detail_lines,
        settlement_lines,
        payment_lines,
        noise_lines
      ].flatten.compact.join("\n") + "\n"
    end

    private

    attr_reader :case_data, :expected, :render

    def custom_lines?
      Array(render["custom_lines"]).any?
    end

    def custom_lines_text
      (Array(render["custom_lines"]) + noise_lines).join("\n") + "\n"
    end

    def header_lines
      [
        expected["store_name"],
        expected["store_address"],
        expected["purchased_at"],
        "領収書",
        separator
      ]
    end

    def item_lines
      expected.fetch("items").map do |item|
        "#{item['name']} #{money(item['line_total'])}"
      end
    end

    def adjustment_lines
      expected.fetch("receipt_adjustments").map do |adjustment|
        "#{adjustment['label']} #{money(signed_amount(adjustment))}"
      end
    end

    def total_lines
      lines = [
        separator,
        "消費税 #{money(expected['tax'])}",
        "合計 #{money(expected['total'])}"
      ]
      lines.insert(1, "小計 #{money(expected['subtotal'])}") unless render["omit_subtotal_line"]
      lines
    end

    def tax_detail_lines
      return [] unless render.fetch("include_tax_detail_lines", true)

      expected.fetch("tax_details").flat_map do |detail|
        rate_label = "#{(BigDecimal(detail['rate'].to_s) * 100).to_i}%"
        if detail["basis"] == "gross"
          [
            "#{rate_label}対象計 #{money(detail['gross'])}",
            "(内税額 #{money(detail['tax'])})"
          ]
        else
          [
            "#{rate_label}対象額 #{money(detail['net'])}",
            "#{rate_label}消費税 #{money(detail['tax'])}"
          ]
        end
      end
    end

    def settlement_lines
      settlement = expected["settlement"]
      return [] if settlement.nil?

      [
        "お預り #{money(settlement['tendered'])}",
        "お釣り #{money(settlement['change'])}"
      ]
    end

    def payment_lines
      lines = expected.fetch("payments").map do |payment|
        "#{payment['label']} #{money(payment['amount'])}"
      end
      lines.unshift("お支払い方法") if render["include_payment_heading"] && lines.any?
      lines
    end

    def noise_lines
      Array(render["noise_lines"])
    end

    def separator
      "-" * (render["paper_width"] == "80mm" ? 40 : 32)
    end

    def money(value)
      amount = value.to_i
      sign = amount.negative? ? "-" : ""
      "#{sign}¥#{amount.abs.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
    end

    def signed_amount(adjustment)
      amount = adjustment["amount"].to_i
      adjustment["sign"] == "surcharge" ? amount : -amount
    end
  end
end
