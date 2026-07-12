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
      def single(user:, image:)
        Single.call(user:, image:)
      end

      def batch(user:, files:)
        Batch.call(user: user, files: files)
      end

      def max_files
        Batch.max_files
      end
    end
  end
end
