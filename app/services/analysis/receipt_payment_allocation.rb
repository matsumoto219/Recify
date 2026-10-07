module Analysis
  class ReceiptPaymentAllocation
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(params:, amount_result:)
      @params = params.deep_dup
      @amount_result = amount_result.with_indifferent_access
      @payment_evidence = (@params[:payment_evidence] || {}).with_indifferent_access
      @amount_max = ReceiptAmountService.receipt_payment_amount_max
    end

    def call
      return params if gift_payments.empty?

      params[:payment_allocation] = { status: "unresolved" }
      return params unless allocation_allowed?

      amount = final_payment_total - other_payments.sum { |payment| payment[:amount].to_i }
      return params unless amount.between?(0, amount_max) && amount <= printed_gift_total

      replacement = { method: gift_payments.first[:method], amount: amount }
      replaced = false
      params[:receipt_payments_attributes] = payments.filter_map do |payment|
        unless payment[:amount_role] == "voucher_tender"
          next payment.slice(:method, :amount).symbolize_keys
        end
        next if replaced

        replaced = true
        replacement
      end
      params[:payment_allocation] = { status: "allocated", amount: amount }
      params
    end

    private

    attr_reader :params, :amount_result, :payment_evidence, :amount_max

    def payments
      @payments ||= Array(payment_evidence[:payments]).map(&:with_indifferent_access)
    end

    def gift_payments
      payments.select { |payment| payment[:amount_role] == "voucher_tender" }
    end

    def other_payments
      payments.reject { |payment| payment[:amount_role] == "voucher_tender" }
    end

    def allocation_allowed?
      settlement = (payment_evidence[:settlement] || {}).with_indifferent_access
      return false unless settlement[:bounded] == true && settlement[:complete] == true && settlement[:ambiguous] == false
      return false unless gift_payments.all? do |payment|
        payment[:method_identity] == "other" && payment[:settlement_use] == true &&
          payment[:settlement_method_key].present? && bounded_amount(payment[:printed_amount])&.positive?
      end
      keys = gift_payments.map { |payment| payment[:settlement_method_key] }.uniq
      return false unless keys.one? && Array(settlement[:gift_tender_method_keys]) == keys
      return false unless other_payments.all? do |payment|
        %w[applied cash_settlement].include?(payment[:amount_role]) &&
          payment[:method_identity].present? && !bounded_amount(payment[:amount]).nil? &&
          !keys.include?(payment[:settlement_method_key])
      end

      final_amount_confirmed? && !final_payment_total.nil?
    end

    def final_amount_confirmed?
      selected = amount_result.dig(:amount_engine, :selected_candidate) || {}
      total = bounded_amount(amount_result.dig(:computed, :purchase_total))
      final = bounded_amount(amount_result.dig(:computed, :final_payment_total))
      adjustment = ReceiptAmountService.parse_amount_or_nil(amount_result.dig(:computed, :payment_adjustment_total))

      amount_result[:selected_candidate_status] == "accepted" &&
        amount_result.dig(:amount_engine, :no_safe_candidate) == false &&
        selected[:hard_reject_reasons] == [] && total && final && adjustment &&
        total == bounded_amount(amount_result.dig(:resolved, :total)) &&
        total == bounded_amount(params.dig(:receipt_attributes, :total_amount)) &&
        total == bounded_amount(selected[:purchase_total]) &&
        final == bounded_amount(selected[:final_payment_total]) && total + adjustment == final
    end

    def final_payment_total
      bounded_amount(amount_result.dig(:computed, :final_payment_total))
    end

    def printed_gift_total
      gift_payments.sum { |payment| bounded_amount(payment[:printed_amount]) }
    end

    def bounded_amount(value)
      amount = ReceiptAmountService.parse_amount_or_nil(value)
      amount.to_i if amount && amount == amount.to_i && amount.between?(0, amount_max)
    end
  end
end
