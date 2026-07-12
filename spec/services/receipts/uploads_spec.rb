require "rails_helper"

RSpec.describe Receipts::Uploads do
  describe ".single" do
    it "single upload workflowへ委譲する" do
      user = build_stubbed(:user)
      image = instance_double(ActionDispatch::Http::UploadedFile)
      result = instance_double("Receipts::Uploads::Single result")
      allow(Receipts::Uploads::Single).to receive(:call).and_return(result)

      expect(described_class.single(user: user, image: image)).to eq(result)
      expect(Receipts::Uploads::Single).to have_received(:call).with(user: user, image: image)
    end
  end

  describe ".batch" do
    it "既存batch upload入口へ委譲する" do
      user = build_stubbed(:user)
      files = [ instance_double(ActionDispatch::Http::UploadedFile) ]
      result = instance_double(Receipts::Uploads::Result)
      allow(Receipts::Uploads::Batch).to receive(:call).and_return(result)

      expect(described_class.batch(user: user, files: files)).to eq(result)
      expect(Receipts::Uploads::Batch).to have_received(:call).with(user: user, files: files)
    end
  end

  describe Receipts::Uploads::Result do
    it "immutable objectとして既存の結果shapeとhelperを維持する" do
      created_receipts = [ build_stubbed(:receipt) ]
      result = described_class.new(created_receipts:, errors: [])

      aggregate_failures do
        expect(result).to be_frozen
        expect(result.success?).to eq(true)
        expect(result.count).to eq(1)
        expect(result.to_h).to eq(created_receipts:, errors: [])
        expect(result.as_json).to eq(
          "created_receipts" => created_receipts.as_json,
          "errors" => []
        )
      end
    end

    it "partial failureの既存判定を維持する" do
      result = described_class.new(
        created_receipts: [ build_stubbed(:receipt) ],
        errors: [ "enqueue failed" ]
      )

      aggregate_failures do
        expect(result.success?).to eq(false)
        expect(result.count).to eq(1)
        expect { result.errors = [] }.to raise_error(NoMethodError)
      end
    end
  end

  describe ".max_files" do
    it "既存batch upload上限を公開する" do
      allow(Receipts::Uploads::Batch).to receive(:max_files).and_return(7)

      expect(described_class.max_files).to eq(7)
    end
  end
end
