module Admin
  module IndexHelper
    AdminIndexPagination = Struct.new(
      :query_base,
      :limit,
      :offset,
      :total_count,
      :start_number,
      :end_number,
      :previous_offset,
      :next_offset,
      :has_previous,
      :has_next,
      keyword_init: true
    ) do
      def has_previous?
        has_previous == true
      end

      def has_next?
        has_next == true
      end
    end

    def admin_index_pagination(result, filters:, parameter_aliases: {})
      query_base = filters.except(:offset).compact_blank
      parameter_aliases.each do |source, target|
        query_base[target] = query_base.delete(source) if query_base.key?(source)
      end

      limit = result.limit
      offset = result.offset
      total_count = result.total_count
      next_offset = offset + limit

      AdminIndexPagination.new(
        query_base: query_base,
        limit: limit,
        offset: offset,
        total_count: total_count,
        start_number: total_count.zero? ? 0 : offset + 1,
        end_number: [ offset + result.records.size, total_count ].min,
        previous_offset: [ offset - limit, 0 ].max,
        next_offset: next_offset,
        has_previous: offset.positive?,
        has_next: next_offset < total_count
      )
    end

    def admin_audit_log_filter_options(values)
      {
        actor_kinds: admin_value_options(values[:actor_kinds]),
        outcomes: admin_value_options(values[:outcomes]),
        limits: admin_limit_options("admin.audit_logs.index.filters.limit_unit")
      }
    end

    def admin_security_event_filter_options(values)
      {
        event_types: admin_value_options(values[:event_types]),
        severities: admin_value_options(values[:severities]),
        states: admin_localized_value_options(values[:states], "admin.security_events.states"),
        limits: admin_limit_options("admin.security_events.index.filters.limit_unit")
      }
    end

    def admin_ip_block_filter_options(values)
      {
        states: admin_localized_value_options(values[:states], "admin.ip_blocks.states"),
        limits: admin_limit_options("admin.ip_blocks.index.filters.limit_unit")
      }
    end

    def admin_contact_request_filter_options(values)
      {
        statuses: admin_localized_value_options(values[:statuses], "admin.contact_requests.statuses"),
        categories: admin_localized_value_options(values[:categories], "admin.contact_requests.categories"),
        sources: admin_localized_value_options(values[:sources], "admin.contact_requests.sources"),
        limits: admin_limit_options("admin.contact_requests.index.filters.limit_unit")
      }
    end

    def admin_announcement_filter_options(values)
      {
        statuses: admin_localized_value_options(values[:statuses], "admin.announcements.statuses"),
        kinds: admin_localized_value_options(values[:kinds], "announcements.kinds"),
        pinned: [
          [ t("admin.announcements.common.yes"), "true" ],
          [ t("admin.announcements.common.no"), "false" ]
        ],
        limits: admin_limit_options("admin.announcements.index.filters.limit_unit")
      }
    end

    def admin_receipt_analysis_run_filter_options(values)
      {
        statuses: admin_value_options(values[:statuses]),
        stages: admin_value_options(values[:stages]),
        sources: admin_value_options(values[:sources]),
        receipt_statuses: admin_value_options(values[:receipt_statuses]),
        needs_attention: [
          [ t("admin.receipt_analysis_runs.index.filters.unspecified"), "" ],
          [ t("admin.receipt_analysis_runs.index.filters.needs_attention_only"), "1" ]
        ],
        limits: admin_limit_options("admin.receipt_analysis_runs.index.filters.limit_unit")
      }
    end

    def admin_user_filter_options
      {
        booleans: [
          [ t("admin.users.common.all"), "" ],
          [ t("admin.users.common.yes_label"), "true" ],
          [ t("admin.users.common.no_label"), "false" ]
        ],
        limits: admin_limit_options("admin.users.common.limit_unit")
      }
    end

    def admin_user_boolean_label(value)
      value ? t("admin.users.common.yes_label") : t("admin.users.common.no_label")
    end

    def admin_short_timestamp_label(value)
      value.present? ? l(value, format: :short) : "-"
    end

    def admin_index_page_params(pagination, direction)
      target_offset = direction == :backward ? pagination.previous_offset : pagination.next_offset

      pagination.query_base.merge(limit: pagination.limit, offset: target_offset)
    end

    private

    def admin_value_options(values)
      Array(values).map { |value| [ value, value ] }
    end

    def admin_localized_value_options(values, locale_scope)
      Array(values).map { |value| [ t("#{locale_scope}.#{value}"), value ] }
    end

    def admin_limit_options(locale_key)
      [ 25, 50, 100 ].map { |value| [ t(locale_key, count: value), value.to_s ] }
    end
  end
end
