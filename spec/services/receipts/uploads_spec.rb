require "rails_helper"

RSpec.describe Receipts::Uploads do
  describe ".batch" do
    it "既存batch upload入口へ委譲する" do
      user = build_stubbed(:user)
      files = [ instance_double(ActionDispatch::Http::UploadedFile) ]
      result = instance_double(ReceiptBatchUploadService::Result)
      allow(ReceiptBatchUploadService).to receive(:call).and_return(result)

      expect(described_class.batch(user: user, files: files)).to eq(result)
      expect(ReceiptBatchUploadService).to have_received(:call).with(user: user, files: files)
    end
  end

  describe ".max_files" do
    it "既存batch upload上限を公開する" do
      allow(ReceiptBatchUploadService).to receive(:max_files).and_return(7)

      expect(described_class.max_files).to eq(7)
    end
  end
end
