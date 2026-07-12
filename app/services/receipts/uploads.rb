module Receipts
  module Uploads
    class << self
      def batch(user:, files:)
        ReceiptBatchUploadService.call(user: user, files: files)
      end

      def max_files
        ReceiptBatchUploadService.max_files
      end
    end
  end
end
