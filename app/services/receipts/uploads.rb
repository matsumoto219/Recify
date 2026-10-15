module Receipts
  module Uploads
    Result = Data.define(:created_receipts, :errors) do
      def success?
        errors.blank?
      end

      def count
        created_receipts.size
      end
    end

    class << self
      def single(user:, image:, operation: nil)
        Single.call(user:, image:, operation:)
      end

      def batch(user:, files:, operation: nil)
        Batch.call(user:, files:, operation:)
      end

      def max_files
        Batch.max_files
      end
    end
  end
end
