module Receipts
  module Uploads
    class << self
      def batch(user:, files:)
        Batch.call(user: user, files: files)
      end

      def max_files
        Batch.max_files
      end
    end
  end
end
