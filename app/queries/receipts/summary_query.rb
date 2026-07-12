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
      category_expression = Arel.sql("COALESCE(NULLIF(receipt_items.category, ''), 'uncategorized')")

      rows = scoped_receipts
        .where(status: AMOUNT_STATUSES)
        .joins(:receipt_items)
        .group(category_expression)
        .pluck(
          category_expression,
          Arel.sql("COALESCE(SUM(receipt_items.line_total), 0)"),
          Arel.sql("COUNT(receipt_items.id)")
        )

      rows.map do |category, total_amount, item_count|
        {
          category: category,
          label: category_label(category),
          total_amount: total_amount.to_i,
          item_count: item_count.to_i
        }
      end.sort_by { |entry| [ -entry[:total_amount], entry[:label] ] }
    end

    private

    attr_reader :user, :scope

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

    def category_label(category)
      return I18n.t("receipts.item_fields.uncategorized") if category == "uncategorized"

      I18n.t("enums.receipt_item.category.#{category}", default: category)
    end
  end
end
