module ReceiptSearch
  class << self
    def validate_query(query)
      QueryValidator.call(query)
    end

    def index_query(scope:, query:, sort:, per_page:)
      IndexQuery.call(scope:, query:, sort:, per_page:)
    end
  end
end
