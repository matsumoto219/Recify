module Receipts
  class SummaryQuery
    AMOUNT_STATUSES = %w[completed review_needed].freeze

    Result = Data.define(
      :receipts_count,
      :current_month_total,
      :previous_month_total,
      :overall_total,
      :processing_count,
      :review_needed_count,
      :failed_count,
      :monthly_change_label,
      :monthly_change_icon,
      :monthly_change_icon_class
    )

    def self.call(user:, scope: nil)
      new(user:, scope:).call
    end

    def self.categories(user:, scope: nil)
      new(user:, scope:).categories
    end

    def initialize(user:, scope: nil)
      @user = user
      @scope = scope
    end

    def call
      current_month_range = Time.current.beginning_of_month..Time.current.end_of_month
      previous_month = 1.month.ago
      previous_month_range = previous_month.beginning_of_month..previous_month.end_of_month
      aggregates = summary_aggregates(receipts, current_month_range, previous_month_range)
      monthly_change = monthly_change_summary(aggregates[:current_month_total], aggregates[:previous_month_total])

      Result.new(
        receipts_count: aggregates[:receipts_count],
        current_month_total: aggregates[:current_month_total],
        previous_month_total: aggregates[:previous_month_total],
        overall_total: aggregates[:overall_total],
        processing_count: aggregates[:processing_count],
        review_needed_count: aggregates[:review_needed_count],
        failed_count: aggregates[:failed_count],
        monthly_change_label: monthly_change[:label],
        monthly_change_icon: monthly_change[:icon],
        monthly_change_icon_class: monthly_change[:icon_class]
      )
    end

    def categories
      scoped_receipts = receipts.where(user_id: user.id).reorder(nil)
      category_expression = normalized_category_expression
      gross_amount = Arel.sql(trusted_gross_amount_sql)
      item_count = ReceiptItem.arel_table[:id].count

      rows = scoped_receipts
        .where(status: AMOUNT_STATUSES)
        .joins(:receipt_items)
        .group(category_expression)
        .pluck(
          category_expression,
          gross_amount.sum,
          item_count,
          item_count - gross_amount.count
        )

      rows.map do |category, total_amount, item_count, unknown_amount_count|
        {
          category: category,
          label: category_label(category),
          total_amount: total_amount&.to_i,
          item_count: item_count.to_i,
          unknown_amount_count: unknown_amount_count.to_i
        }
      end.sort_by { |entry| [ entry[:total_amount].nil? ? 1 : 0, -entry[:total_amount].to_i, entry[:label] ] }
    end

    private

    attr_reader :user, :scope

    def trusted_gross_amount_sql
      maximum = ReceiptItem::GROSS_LINE_TOTAL_MAX
      origins = ReceiptCalculationSettings::ORIGINS.map { |value| Receipt.connection.quote(value) }.join(", ")
      <<~SQL.squish
        CASE
          WHEN receipt_items.gross_line_total IS NOT NULL THEN
            CASE WHEN receipt_items.gross_line_total BETWEEN 0 AND #{maximum} THEN receipt_items.gross_line_total END
          WHEN receipt_items.line_total BETWEEN 0 AND #{maximum} AND (
            (receipt_items.pricing_source_kind IN ('count_unit_price', 'explicit_line_total')
              AND receipt_items.input_tax_inclusion = 'gross' AND receipt_items.tax_inclusion_origin IN (#{origins}))
            OR (receipt_items.pricing_source_kind = 'reference_quantity_price'
              AND receipt_items.input_tax_inclusion IS NULL AND receipt_items.reference_price_tax_inclusion = 'gross')
            OR (#{legacy_gross_projection_sql})
          ) THEN receipt_items.line_total
        END
      SQL
    end

    def legacy_gross_projection_sql
      profile = "receipts.amount_calculation_profile"
      engine = "#{profile} -> 'amount_engine'"
      candidate = "#{engine} -> 'selected_candidate'"
      <<~SQL.squish
        receipts.calculation_settings IS NULL AND receipt_items.input_tax_inclusion IS NULL
        AND #{profile} -> 'schema_version' = '1'::jsonb
        AND #{profile} ->> 'schema_version' = '1'
        AND #{profile} ->> 'selected_candidate_status' = 'accepted'
        AND (#{profile} ->> 'context' = 'manual'
          OR (#{profile} ->> 'context' = 'analysis' AND receipt_items.pricing_source_kind IS NULL))
        AND #{engine} -> 'schema_version' = '1'::jsonb
        AND #{engine} ->> 'schema_version' = '1'
        AND #{engine} ->> 'selected_candidate_status' = 'accepted'
        AND #{engine} -> 'no_safe_candidate' = 'false'::jsonb
        AND #{engine} ->> 'selected_basis' IN ('items_as_tax_included', 'items_as_tax_excluded')
        AND #{candidate} -> 'hard_reject_reasons' = '[]'::jsonb
        AND #{candidate} ->> 'basis' = #{engine} ->> 'selected_basis'
        AND #{candidate} ->> 'candidate_id' = #{engine} ->> 'selected_candidate_id'
        AND #{candidate} ->> 'rounding_mode' IN ('floor', 'round', 'ceil')
        AND #{candidate} ->> 'rounding_scope' IN ('per_item', 'per_tax_rate_group', 'per_receipt')
        AND #{candidate} ->> 'candidate_id' = CONCAT(
          #{candidate} ->> 'basis', '/', #{candidate} ->> 'rounding_mode', '/', #{candidate} ->> 'rounding_scope')
      SQL
    end

    def receipts
      scope || user.receipts
    end

    def summary_aggregates(relation, current_month_range, previous_month_range)
      row = relation.reorder(nil).pick(
        Arel.sql("COUNT(*)"),
        Arel.sql(summary_sum_sql(amount_status_condition, :total_amount)),
        Arel.sql(summary_sum_sql("#{amount_status_condition} AND #{range_condition(:purchased_at, current_month_range)}", :total_amount)),
        Arel.sql(summary_sum_sql("#{amount_status_condition} AND #{range_condition(:purchased_at, previous_month_range)}", :total_amount)),
        Arel.sql(summary_count_sql(status_condition("processing"))),
        Arel.sql(summary_count_sql(status_condition("review_needed"))),
        Arel.sql(summary_count_sql(status_condition("failed")))
      )
      row ||= []

      {
        receipts_count: row[0].to_i,
        overall_total: row[1].to_i,
        current_month_total: row[2].to_i,
        previous_month_total: row[3].to_i,
        processing_count: row[4].to_i,
        review_needed_count: row[5].to_i,
        failed_count: row[6].to_i
      }
    end

    def summary_sum_sql(condition, column)
      "COALESCE(SUM(CASE WHEN #{condition} THEN #{summary_column(column)} ELSE 0 END), 0)"
    end

    def summary_count_sql(condition)
      "COALESCE(SUM(CASE WHEN #{condition} THEN 1 ELSE 0 END), 0)"
    end

    def amount_status_condition
      quoted_statuses = AMOUNT_STATUSES.map { |status| Receipt.connection.quote(status) }.join(", ")
      "#{summary_column(:status)} IN (#{quoted_statuses})"
    end

    def status_condition(status)
      "#{summary_column(:status)} = #{Receipt.connection.quote(status)}"
    end

    def range_condition(column, range)
      "#{summary_column(column)} BETWEEN #{Receipt.connection.quote(range.begin)} AND #{Receipt.connection.quote(range.end)}"
    end

    def summary_column(column)
      "#{Receipt.quoted_table_name}.#{Receipt.connection.quote_column_name(column)}"
    end

    def monthly_change_summary(current_month_total, previous_month_total)
      current_total = current_month_total.to_i
      previous_total = previous_month_total.to_i

      return {
        label: I18n.t("dashboard.summary.amount.no_previous_month"),
        icon: "trending_flat",
        icon_class: "token-text-muted"
      } if previous_total.zero?

      change_rate = ((current_total - previous_total).to_d / previous_total * 100).round

      if change_rate.positive?
        {
          label: I18n.t("dashboard.summary.amount.monthly_change", value: "+#{change_rate}"),
          icon: "trending_up",
          icon_class: "token-text-error"
        }
      elsif change_rate.negative?
        {
          label: I18n.t("dashboard.summary.amount.monthly_change", value: change_rate.to_s),
          icon: "trending_down",
          icon_class: "token-text-success"
        }
      else
        {
          label: I18n.t("dashboard.summary.amount.monthly_change", value: "±0"),
          icon: "trending_flat",
          icon_class: "token-text-muted"
        }
      end
    end

    def normalized_category_expression
      category = ReceiptItem.arel_table[:category]

      Arel::Nodes::Case.new
        .when(category.in(ReceiptItem::CATEGORIES))
        .then(category)
        .else("uncategorized")
    end

    def category_label(category)
      return I18n.t("receipts.item_fields.uncategorized") if category == "uncategorized"

      I18n.t("enums.receipt_item.category.#{category}", default: category)
    end
  end
end
