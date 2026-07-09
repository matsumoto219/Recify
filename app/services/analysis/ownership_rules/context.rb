module Analysis
  module OwnershipRules
    class Context
      def initialize(proposal:, lines:, items:, payments:, tax_details:, profile:)
        @proposal = normalized_hash(proposal)
        @lines = Array(lines)
        @items = Array(items)
        @payments = Array(payments)
        @tax_details = Array(tax_details)
        @profile = profile
      end

      attr_reader :proposal, :lines, :items, :payments, :tax_details, :profile

      def kind
        @kind ||= ReceiptAdjustment.normalize_kind(proposal[:kind])
      end

      def sign
        @sign ||= (proposal[:sign].presence || proposal[:sign_hint]).to_s
      end

      def valid_kind?
        ReceiptAdjustment::KINDS.include?(kind)
      end

      def valid_sign?
        ReceiptAdjustment::SIGNS.include?(sign)
      end

      def amount
        @amount ||= ReceiptAmountService.parse_amount(proposal[:amount]).to_i.abs
      end

      def source_line_index
        @source_line_index ||= Integer(proposal[:source_line_index], exception: false)
      end

      def source_line
        return "" if source_line_index.nil?

        lines[source_line_index].to_s
      end

      def text
        @text ||= [ proposal[:label], proposal[:source_text], source_line ].compact.join(" ").unicode_normalize(:nfkc)
      end

      def context_text(before: 1, after: 1)
        return text if source_line_index.nil?

        ([ proposal[:label], proposal[:source_text] ] + lines_around(before: before, after: after)).compact.join(" ").unicode_normalize(:nfkc)
      end

      def bag_fee_text?
        text.match?(profile.bag_fee_owned_label_pattern)
      end

      def bag_item_text?
        return false if bag_fee_text?

        text.match?(profile.bag_item_owned_label_pattern)
      end

      def inferred_surcharge_kind
        return kind if ReceiptAdjustment::SURCHARGE_KINDS.include?(kind)

        {
          "late_night_charge" => profile.analysis_late_night_charge_kind_pattern,
          "service_charge" => profile.analysis_service_charge_kind_pattern,
          "delivery_fee" => profile.analysis_delivery_fee_kind_pattern,
          "bag_fee" => profile.analysis_bag_fee_kind_pattern,
          "handling_fee" => profile.analysis_handling_fee_kind_pattern
        }.find { |_candidate_kind, pattern| text.match?(pattern) }&.first
      end

      def explicit_surcharge_text?(candidate_kind)
        pattern = profile.analysis_surcharge_kind_pattern(candidate_kind)
        pattern.present? && text.match?(pattern)
      end

      def return_refund_text?
        text.match?(profile.analysis_return_refund_kind_pattern)
      end

      def coupon_text?
        text.match?(profile.analysis_coupon_kind_pattern)
      end

      def receipt_discount_text?
        text.match?(profile.analysis_receipt_discount_kind_pattern)
      end

      def cashless_reward_text?
        text.match?(profile.analysis_cashless_reward_adjustment_pattern) ||
          text.match?(profile.ocr_payment_adjustment_discount_label_pattern)
      end

      def point_usage_text?
        text.match?(profile.ocr_point_usage_adjustment_label_pattern) ||
          text.match?(profile.analysis_point_payment_line_pattern) ||
          text.match?(profile.analysis_point_usage_kind_pattern)
      end

      def point_text?
        kind == "point_usage" ||
          point_usage_text? ||
          text.match?(profile.analysis_point_only_text_pattern) ||
          text.match?(profile.analysis_point_display_line_pattern)
      end

      def informational_point_text?
        return false if point_usage_text?

        text.match?(profile.analysis_point_display_line_pattern) ||
          !text.match?(profile.analysis_point_money_context_pattern)
      end

      def voucher_text?
        text.match?(profile.analysis_voucher_payment_pattern)
      end

      def payment_owned?
        return false unless payment_amount_matches?

        text.match?(profile.analysis_fallback_payment_line_pattern) ||
          context_text.match?(profile.analysis_payment_block_anchor_pattern)
      end

      def tax_detail_owned?
        return true if direct_tax_detail_text?

        tax_detail_amount_matches? && tax_detail_context_text?
      end

      def item_owned?
        items.any? do |item|
          attributes = normalized_hash(item)
          item_amounts(attributes).include?(amount) && source_matches_item?(attributes)
        end
      end

      def item_discount_owned?
        return false unless item_discount_amounts.include?(amount)

        context = lines_around(before: 4, after: 4)
        discount_label_present = context.any? { |line| line.match?(profile.analysis_item_discount_label_pattern) }
        signed_amount_present = context.any? do |line|
          line.match?(/[▲△\-−]/) && money_amounts(line).include?(amount)
        end
        rate_present = context.any? { |line| line.match?(/\d+(?:\.\d+)?\s*[%％]/) }

        discount_label_present && signed_amount_present && rate_present && !receipt_level_adjustment_context?
      end

      def receipt_level_adjustment_context?
        return false if source_line_index.nil?
        return true if source_line.match?(profile.analysis_receipt_level_adjustment_line_pattern)

        lines_before(2).any? { |line| line.match?(profile.analysis_previous_subtotal_context_pattern) }
      end

      def post_settlement_promo?
        return false if source_line_index.nil?
        return false unless text.match?(profile.analysis_post_settlement_promo_adjustment_pattern)
        return false unless settlement_boundary_before?

        context_text(before: 4, after: 4).match?(profile.analysis_post_settlement_promo_context_pattern)
      end

      private

      def lines_around(before:, after:)
        return [] if source_line_index.nil? || source_line_index.negative?

        start_index = [ source_line_index - before, 0 ].max
        end_index = [ source_line_index + after, lines.length - 1 ].min
        lines[start_index..end_index].to_a.map(&:to_s)
      end

      def lines_before(count)
        return [] if source_line_index.nil? || source_line_index.zero?

        start_index = [ source_line_index - count, 0 ].max
        lines[start_index...source_line_index].to_a.map(&:to_s)
      end

      def settlement_boundary_before?
        lines[0...source_line_index].to_a.reverse.take(20).any? do |line|
          line.to_s.match?(profile.analysis_post_settlement_boundary_pattern)
        end
      end

      def direct_tax_detail_text?
        source_line.match?(profile.ocr_tax_amount_description_pattern) ||
          (source_line.match?(profile.ocr_tax_target_marker_pattern) && source_line.match?(/\d+(?:\.\d+)?\s*[%％]/))
      end

      def tax_detail_context_text?
        source = context_text
        source.match?(profile.ocr_tax_context_label_pattern) ||
          source.match?(profile.ocr_tax_target_marker_pattern) ||
          source.match?(profile.ocr_tax_amount_description_pattern)
      end

      def tax_detail_amount_matches?
        tax_details.any? do |tax_detail|
          attributes = normalized_hash(tax_detail)
          %i[amount net_amount].filter_map do |key|
            ReceiptAmountService.parse_amount_or_nil(attributes[key])&.to_i&.abs
          end.include?(amount)
        end
      end

      def payment_amount_matches?
        payments.any? do |payment|
          attributes = normalized_hash(payment)
          ReceiptAmountService.parse_amount(attributes[:amount]).to_i.abs == amount
        end
      end

      def source_matches_item?(item)
        normalized_source_line = compact_text(source_line)
        return false if normalized_source_line.blank?

        item_texts(item).any? do |item_text|
          normalized_item = compact_text(item_text)
          normalized_item.present? && (
            normalized_item == normalized_source_line ||
            normalized_item.include?(normalized_source_line) ||
            normalized_source_line.include?(normalized_item)
          )
        end
      end

      def item_texts(item)
        %i[raw_text suggested_name confirmed_name source_text].filter_map { |key| item[key].presence }
      end

      def item_amounts(item)
        %i[line_total price original_line_total].filter_map do |key|
          ReceiptAmountService.parse_amount_or_nil(item[key])&.to_i&.abs
        end.select(&:positive?)
      end

      def item_discount_amounts
        items.filter_map do |item|
          ReceiptAmountService.parse_amount_or_nil(normalized_hash(item)[:discount_amount])&.to_i&.abs
        end.select(&:positive?).uniq
      end

      def money_amounts(value)
        MoneyTokenClassifier.money_matches(
          text: value,
          money_pattern: profile.analysis_adjustment_amount_candidate_pattern,
          profile: profile,
          allow_bare_money: true
        ).map { |token| token[:amount] }
      end

      def compact_text(value)
        value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]　,，¥￥:：]+/, "")
      end

      def normalized_hash(value)
        return value.to_h.with_indifferent_access if value.respond_to?(:to_h)

        {}.with_indifferent_access
      end
    end
  end
end
