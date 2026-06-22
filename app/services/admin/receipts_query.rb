# frozen_string_literal: true

module Admin
  class ReceiptsQuery
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 50
    SAMPLE_LIMIT = 10

    Result = Struct.new(:records, :limit, :offset, :total_count, keyword_init: true)

    class << self
      def call(**filters)
        new(**filters).call
      end

      def find(public_id:)
        new(public_id: public_id, limit: 1).call.records.first
      end
    end

    def initialize(public_id: nil, user_id: nil, limit: DEFAULT_LIMIT, offset: 0)
      @public_id = public_id
      @user_id = user_id
      @limit = normalize_limit(limit)
      @offset = normalize_offset(offset)
    end

    def call
      relation = filtered_relation
      total_count = relation.count
      receipts = relation.order(created_at: :desc, id: :desc).limit(@limit).offset(@offset).to_a

      Result.new(
        records: receipts.map { |receipt| build_record(receipt) },
        limit: @limit,
        offset: @offset,
        total_count: total_count
      )
    end

    private

    def filtered_relation
      relation = Receipt.includes(
        :user,
        :quarantined_by,
        :quarantine_released_by,
        :quarantine_source_security_event,
        image_attachment: :blob
      )
      relation = filter_by_public_id(relation)
      filter_by_user(relation)
    end

    def filter_by_public_id(relation)
      public_id = @public_id.to_s.strip
      return relation if public_id.blank?

      relation.where(public_id: public_id)
    end

    def filter_by_user(relation)
      user_id = positive_integer(@user_id)
      return relation if user_id.blank?

      relation.where(user_id: user_id)
    end

    def build_record(receipt)
      {
        receipt: receipt,
        id: receipt.id,
        public_id: receipt.public_id,
        display_id: receipt.display_id,
        status: receipt.status,
        moderation_status: receipt.moderation_status,
        store_name: receipt.store_name,
        purchased_at: receipt.purchased_at,
        total_amount: receipt.total_amount,
        payment_method: receipt.payment_method,
        owner: user_record(receipt.user),
        moderation: moderation_record(receipt),
        image: image_record(receipt),
        counts: counts_record(receipt),
        recent_items: recent_items(receipt),
        recent_adjustments: recent_adjustments(receipt),
        recent_analysis_runs: recent_analysis_runs(receipt),
        recent_notifications: recent_notifications(receipt),
        audit_target_uid: "receipt:#{receipt.public_id}",
        timestamps: {
          created_at: receipt.created_at,
          updated_at: receipt.updated_at
        }
      }
    end

    def user_record(user)
      {
        id: user.id,
        email: user.email,
        guest: user.guest?,
        admin: user.admin?
      }
    end

    def moderation_record(receipt)
      {
        status: receipt.moderation_status,
        quarantined: receipt.quarantined?,
        active_for_user: receipt.active_for_user?,
        quarantined_at: receipt.quarantined_at,
        quarantined_by: compact_user(receipt.quarantined_by),
        quarantine_reason: receipt.quarantine_reason,
        released_at: receipt.quarantine_released_at,
        released_by: compact_user(receipt.quarantine_released_by),
        released_reason: receipt.quarantine_released_reason,
        source_security_event: compact_security_event(receipt.quarantine_source_security_event),
        quarantine_allowed: receipt.moderation_active?,
        release_allowed: receipt.moderation_quarantined?
      }
    end

    def image_record(receipt)
      attachment = receipt.image.attachment if receipt.image.attached?
      blob = attachment&.blob

      {
        attached: attachment.present?,
        filename: blob&.filename&.to_s,
        content_type: blob&.content_type,
        byte_size: blob&.byte_size,
        attached_at: attachment&.created_at,
        keep_image: receipt.keep_image?,
        purge_eligible_at: receipt.image_purge_eligible_at,
        purged_at: receipt.image_purged_at,
        purged_reason: receipt.image_purged_reason
      }
    end

    def counts_record(receipt)
      {
        items: receipt.receipt_items.size,
        adjustments: receipt.receipt_adjustments.size,
        payments: receipt.receipt_payments.size,
        tax_details: receipt.receipt_tax_details.size,
        analysis_runs: receipt.receipt_analysis_runs.size,
        notifications: receipt.notifications.size
      }
    end

    def recent_items(receipt)
      receipt.receipt_items.order(:position_index, :id).limit(SAMPLE_LIMIT).map do |item|
        {
          id: item.id,
          name: item.confirmed_name.presence || item.suggested_name.presence,
          line_total: item.line_total,
          needs_review: item.needs_review?
        }
      end
    end

    def recent_adjustments(receipt)
      receipt.receipt_adjustments.order(:position_index, :id).limit(SAMPLE_LIMIT).map do |adjustment|
        {
          id: adjustment.id,
          kind: adjustment.kind,
          label: adjustment.label,
          amount: adjustment.amount,
          sign: adjustment.sign,
          needs_review: adjustment.needs_review?
        }
      end
    end

    def recent_analysis_runs(receipt)
      receipt.receipt_analysis_runs.order(created_at: :desc, id: :desc).limit(SAMPLE_LIMIT).map do |run|
        {
          id: run.id,
          run_key: run.run_key,
          stage: run.stage,
          status: run.status,
          source: run.source,
          error_code: run.error_code,
          created_at: run.created_at
        }
      end
    end

    def recent_notifications(receipt)
      receipt.notifications.order(created_at: :desc, id: :desc).limit(SAMPLE_LIMIT).map do |notification|
        {
          id: notification.id,
          uid: notification.uid,
          kind: notification.kind,
          title: notification.title,
          read_at: notification.read_at,
          created_at: notification.created_at
        }
      end
    end

    def compact_user(user)
      return if user.blank?

      {
        id: user.id,
        email: user.email
      }
    end

    def compact_security_event(event)
      return if event.blank?

      {
        id: event.id,
        event_type: event.event_type,
        matched_rule: event.matched_rule
      }
    end

    def normalize_limit(value)
      normalized = value.to_i
      normalized = DEFAULT_LIMIT if normalized <= 0

      [ normalized, MAX_LIMIT ].min
    end

    def normalize_offset(value)
      [ value.to_i, 0 ].max
    end

    def positive_integer(value)
      integer = value.to_i
      integer.positive? ? integer : nil
    end
  end
end
