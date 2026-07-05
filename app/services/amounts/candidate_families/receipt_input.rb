# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class ReceiptInput < Base
      def call
        delegate(:receipt_input_candidate)
      end
    end
  end
end
