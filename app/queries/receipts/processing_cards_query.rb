module Receipts
  class ProcessingCardsQuery
    MAX_IDS = 100

    Entry = Data.define(:public_id, :requested_state_revision, :receipt, :analysis_run)
    Result = Data.define(:entries)

    def self.call(user:, public_ids:, state_revisions:)
      new(user:, public_ids:, state_revisions:).call
    end

    def initialize(user:, public_ids:, state_revisions:)
      @user = user
      @public_ids = public_ids
      @state_revisions = state_revisions
    end

    def call
      requests = normalized_requests
      receipts = user.receipts.active_for_user.where(public_id: requests.keys).to_a
      receipts_by_public_id = receipts.index_by(&:public_id)
      runs_by_receipt_id = latest_active_runs_by_receipt_id(receipts)

      entries = requests.map do |public_id, requested_state_revision|
        receipt = receipts_by_public_id[public_id]
        Entry.new(
          public_id: public_id,
          requested_state_revision: requested_state_revision,
          receipt: receipt,
          analysis_run: receipt ? runs_by_receipt_id[receipt.id] : nil
        )
      end.freeze

      Result.new(entries: entries)
    end

    private

    attr_reader :user, :public_ids, :state_revisions

    def normalized_requests
      revisions = Array(state_revisions)

      Array(public_ids).each_with_index.each_with_object({}) do |(raw_public_id, index), requests|
        break requests if requests.size >= MAX_IDS

        public_id = raw_public_id.to_s
        next unless Receipt::PUBLIC_ID_FORMAT.match?(public_id)
        next if requests.key?(public_id)

        requests[public_id] = revisions[index].to_s
      end
    end

    def latest_active_runs_by_receipt_id(receipts)
      ReceiptAnalysisRun
        .active
        .where(receipt_id: receipts.map(&:id))
        .order(:created_at)
        .index_by(&:receipt_id)
    end
  end
end
