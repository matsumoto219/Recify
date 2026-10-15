module Receipts
  module Registrations
    class InvalidOperation < StandardError
      def initialize
        super("registration operation unavailable")
      end
    end

    Handle = Data.define(:id, :user_id, :operation_key, :attempt_key)

    Result = Data.define(:state, :kind, :receipt_ids, :value, :replayed) do
      def initialize(state:, kind: nil, receipt_ids: [], value: nil, replayed: false)
        super(state: state.freeze, kind: kind&.freeze, receipt_ids: receipt_ids.dup.freeze, value:, replayed:)
      end

      def accepted?
        state == "accepted"
      end

      def replayed?
        replayed == true
      end
    end

    class << self
      def issue_token(user:, kind:)
        Token.issue(user:, kind:)
      end

      def report_failure(operation:, reason:)
        Notifications.report(operation:, reason:)
      end

      def with_operation(user:, token:, kind:, input:, &operation)
        Coordinator.call(user:, token:, kind:, input:, &operation)
      end

      def accept!(operation:, receipts:)
        Coordinator.accept!(operation:, receipts:)
      end

      def cleanup_expired(limit: 100, after_id: 0, through_id: nil)
        Cleanup.call(limit:, after_id:, through_id:)
      end
    end
  end
end
