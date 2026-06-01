module ReceiptSearch
  class << self
    def validate_query(query)
      QueryValidator.call(query)
    end
  end
end
