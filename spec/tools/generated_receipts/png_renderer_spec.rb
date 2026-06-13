# frozen_string_literal: true

require "chunky_png"
require "tmpdir"
require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::PngRenderer do
  def load_case(name)
    GeneratedReceipts::Validator.load_file(File.join(GeneratedReceipts::CASES_DIR, "#{name}.json"))
  end

  it "renders a readable PNG from a generated receipt case" do
    skip "Chrome is not available" unless described_class.available?

    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "receipt.png")
      described_class.call(load_case("g001_normal_included_10_cash"), output_path: output_path)
      image = ChunkyPNG::Image.from_file(output_path)

      aggregate_failures do
        expect(File.binread(output_path, 8)).to eq("\x89PNG\r\n\x1A\n".b)
        expect(image.width).to eq(320)
        expect(image.height).to be > 300
      end
    end
  end
end
