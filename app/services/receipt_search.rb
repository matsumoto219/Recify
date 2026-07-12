module ReceiptSearch
  class << self
    def validate_query(query)
      Receipts::SearchForm.call(query)
    end

    def index_query(scope:, query:, sort:, per_page:)
      Receipts::IndexQuery.call(scope:, query:, sort:, per_page:)
    end
  end
end
