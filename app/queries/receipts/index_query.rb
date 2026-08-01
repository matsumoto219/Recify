module Receipts
  class IndexQuery
    DEFAULT_SORT = "newest".freeze
    DEFAULT_PER_PAGE = 20
    SORT_OPTIONS = %w[
      newest
      oldest
      purchased_at_desc
      purchased_at_asc
      amount_desc
      amount_asc
      store_name
      updated
      review_priority
    ].freeze
    PER_PAGE_OPTIONS = [ 20, 50, 100 ].freeze

    Result = Data.define(:scope, :query, :sort, :per_page, :sanitized_params) do
      def pagination_params
        sanitized_params
      end

      def default_index_view?
        sort == DEFAULT_SORT && per_page == DEFAULT_PER_PAGE
      end
    end

    def self.call(scope:, query:, sort:, per_page:)
      new(scope:, query:, sort:, per_page:).call
    end

    def initialize(scope:, query:, sort:, per_page:)
      @scope = scope
      @query = query.to_s
      @sort = normalize_sort(sort)
      @per_page = normalize_per_page(per_page)
    end

    def call
      Result.new(
        scope: sorted_scope,
        query: query,
        sort: sort,
        per_page: per_page,
        sanitized_params: sanitized_params
      )
    end

    private

    attr_reader :scope, :query, :sort, :per_page

    def sorted_scope
      search_scope = SearchQuery.call(scope: scope, query: query)
      receipts = search_scope.klass.arel_table

      case sort
      when "oldest"
        search_scope.reorder(created_at: :asc)
      when "purchased_at_desc"
        search_scope.reorder(receipts[:purchased_at].desc.nulls_last, receipts[:id].desc)
      when "purchased_at_asc"
        search_scope.reorder(receipts[:purchased_at].asc.nulls_last, receipts[:id].asc)
      when "amount_desc"
        search_scope.reorder(Arel.sql("CASE WHEN receipts.total_amount IS NULL THEN 1 ELSE 0 END ASC, receipts.total_amount DESC"))
      when "amount_asc"
        search_scope.reorder(Arel.sql("CASE WHEN receipts.total_amount IS NULL THEN 1 ELSE 0 END ASC, receipts.total_amount ASC"))
      when "store_name"
        search_scope.reorder(Arel.sql("CASE WHEN receipts.store_name IS NULL THEN 2 WHEN receipts.store_name = '' THEN 1 ELSE 0 END ASC, receipts.store_name ASC"))
      when "updated"
        search_scope.reorder(updated_at: :desc)
      when "review_priority"
        search_scope.reorder(Arel.sql("CASE WHEN receipts.status = 'review_needed' THEN 0 ELSE 1 END ASC"), created_at: :desc)
      else
        search_scope.reorder(created_at: :desc)
      end
    end

    def sanitized_params
      params = {}
      params[:q] = query if query.present?
      params[:sort] = sort unless sort == DEFAULT_SORT
      params[:per_page] = per_page.to_s unless per_page == DEFAULT_PER_PAGE
      params
    end

    def normalize_sort(value)
      normalized = value.to_s
      SORT_OPTIONS.include?(normalized) ? normalized : DEFAULT_SORT
    end

    def normalize_per_page(value)
      normalized = Integer(value, exception: false)
      PER_PAGE_OPTIONS.include?(normalized) ? normalized : DEFAULT_PER_PAGE
    end
  end
end
