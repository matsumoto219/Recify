module Receipts
  class SearchQuery
    MAX_TOKENS = 5
    DATE_PATTERN = "\\d{4}[\\/-]\\d{2}[\\/-]\\d{2}".freeze
    AMOUNT_PATTERN = /\A(?:amount|total)?\s*(<=|>=|<|>|=)?\s*(\d+)\z/.freeze

    def self.call(scope:, query:)
      new(scope:, query:).call
    end

    def initialize(scope:, query:)
      @scope = scope
      @query = query
    end

    def call
      return scope if query.blank?

      tokens = query.to_s.strip.split(/\s+/).first(MAX_TOKENS)
      return scope.none if tokens.empty?

      tokens.reduce(scope) do |result_scope, token|
        result_scope.merge(scope_for_token(token))
      end
    end

    private

    attr_reader :scope, :query

    def scope_for_token(token)
      token_scope = text_scope(token)
      token_scope = add_exact_date_scope(token_scope, token)
      token_scope = add_date_operator_scope(token_scope, token)
      add_amount_scope(token_scope, token)
    end

    def text_scope(token)
      query_pattern = "%#{scope.klass.sanitize_sql_like(token)}%"
      matching_ids = scope.left_joins(:receipt_items).unscope(:order).where(
        "receipts.store_name ILIKE :q OR receipts.memo ILIKE :q OR receipt_items.confirmed_name ILIKE :q OR receipt_items.suggested_name ILIKE :q OR receipt_items.raw_text ILIKE :q",
        q: query_pattern
      ).select(:id)

      scope.where(id: matching_ids)
    end

    def add_exact_date_scope(token_scope, token)
      date = Date.parse(token)
      token_scope.or(scope.where(purchased_at: date.beginning_of_day..date.end_of_day))
    rescue ArgumentError
      token_scope
    end

    def add_date_operator_scope(token_scope, token)
      normalized = token.strip

      if normalized =~ /\Adate:(#{DATE_PATTERN})\.\.(#{DATE_PATTERN})\z/
        from = parse_date($1)
        to = parse_date($2)
        token_scope = from && to ? token_scope.or(scope.where(purchased_at: from.beginning_of_day..to.end_of_day)) : scope.none
      end

      if normalized =~ /\Adate>=?(#{DATE_PATTERN})\z/
        from = parse_date($1)
        token_scope = from ? token_scope.or(scope.where("purchased_at >= ?", from.beginning_of_day)) : scope.none
      end

      if normalized =~ /\Adate<=?(#{DATE_PATTERN})\z/
        to = parse_date($1)
        token_scope = to ? token_scope.or(scope.where("purchased_at <= ?", to.end_of_day)) : scope.none
      end

      token_scope
    end

    def add_amount_scope(token_scope, token)
      condition = token.delete(",").downcase.match(AMOUNT_PATTERN)
      return token_scope unless condition

      operator = condition[1].presence || "="
      amount = condition[2].to_i
      amount_column = scope.klass.arel_table[:total_amount]
      predicate = case operator
      when "<=" then amount_column.lteq(amount)
      when ">=" then amount_column.gteq(amount)
      when "<" then amount_column.lt(amount)
      when ">" then amount_column.gt(amount)
      else amount_column.eq(amount)
      end

      token_scope.or(scope.where(predicate))
    end

    def parse_date(value)
      Date.parse(value)
    rescue ArgumentError
      nil
    end
  end
end
