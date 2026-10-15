module Receipts::Registrations
  class Notifications
    KIND = "receipt_upload_failed".freeze
    REASONS = %w[storage_failed].freeze
    private_constant :KIND, :REASONS

    class << self
      def report(operation:, reason:)
        return false unless operation.is_a?(Handle) && REASONS.include?(reason)

        ReceiptRegistrationOperation.transaction(requires_new: true) do
          owner = User.lock.find(operation.user_id)
          record = owner.receipt_registration_operations.lock.find(operation.id)
          next false unless matches_attempt?(record, operation)
          next true if record.notification_reported

          create_notification(owner, record, reason)
          record.update!(state: "failed", notification_reported: true)
          true
        end
      rescue ActiveRecord::RecordNotFound
        false
      rescue StandardError => error
        Rails.logger.warn("[ReceiptRegistration] notification_failed error_class=#{error.class.name}")
        false
      end

      private

      def matches_attempt?(record, operation)
        record.operation_key == operation.operation_key && record.attempt_key == operation.attempt_key &&
          record.state.in?(%w[processing failed]) && record.receipt_ids.empty? && record.accepted_at.nil?
      end

      def create_notification(user, record, reason)
        paths = Rails.application.routes.url_helpers
        user.notifications.create!(
          kind: KIND,
          notifiable: record,
          title: I18n.t("receipt_registration.notification.title"),
          body: I18n.t(
            "receipt_registration.notification.body",
            reason: I18n.t("receipt_registration.notification.reasons.#{reason}"),
            code: reason
          ),
          action_path: record.kind == "manual" ? paths.new_receipt_path : paths.new_upload_receipts_path,
          metadata: { reason: reason }
        )
      end
    end
  end
end
