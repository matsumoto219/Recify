# frozen_string_literal: true

require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::DegradationProfiles do
  it "defines named profiles without applying them yet" do
    aggregate_failures do
      expect(described_class.names).to contain_exactly("mild", "medium", "severe")
      described_class.names.each do |name|
        expect(described_class.fetch(name).keys - described_class::EFFECTS).to eq([])
      end
    end
  end
end
