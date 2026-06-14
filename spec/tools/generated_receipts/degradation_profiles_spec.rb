# frozen_string_literal: true

require "tmpdir"
require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::DegradationProfiles do
  it "defines named profiles with supported effects" do
    aggregate_failures do
      expect(described_class.names).to contain_exactly("mild", "medium", "severe")
      described_class.names.each do |name|
        expect(described_class.fetch(name).keys - described_class::EFFECTS).to eq([])
      end
    end
  end
end

RSpec.describe GeneratedReceipts::Degrader do
  it "applies a deterministic profile to a PNG file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "receipt.png")
      image = ChunkyPNG::Image.new(12, 12, ChunkyPNG::Color::WHITE)
      3.upto(8) { |index| image[index, 6] = ChunkyPNG::Color::BLACK }
      image.save(path)

      case_data = {
        "case_id" => "degrader_spec",
        "degradation" => { "enabled" => true, "profile" => "mild" }
      }

      described_class.call(case_data, image_path: path)

      expect(File).to exist(path)
      expect(ChunkyPNG::Image.from_file(path).pixels).not_to eq(image.pixels)
    end
  end
end
