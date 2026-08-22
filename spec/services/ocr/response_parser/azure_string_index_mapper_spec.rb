require "rails_helper"
require "timeout"

RSpec.describe Ocr::ResponseParser::AzureStringIndexMapper do
  describe ".build" do
    it "supports only the Azure index types whose boundaries are implemented exactly" do
      aggregate_failures do
        expect(described_class.build(index_type: "utf16CodeUnit")).to be_a(described_class)
        expect(described_class.build(index_type: "textElements")).to be_a(described_class)
        expect(described_class.build(index_type: "unicodeCodePoint")).to be_nil
        expect(described_class.build(index_type: "UTF16CodeUnit")).to be_nil
        expect(described_class.build(index_type: :textElements)).to be_nil
        expect(described_class.build(index_type: nil)).to be_nil
      end
    end
  end

  describe "provider unit mapping" do
    subject(:mapper) { described_class.build(index_type:) }

    let(:content) { "A日😀éZ" }

    context "with utf16CodeUnit" do
      let(:index_type) { "utf16CodeUnit" }

      it "counts ASCII, BMP characters, surrogate pairs, and combining code points as UTF-16 units" do
        aggregate_failures do
          expect(mapper.length("ASCII")).to eq(5)
          expect(mapper.length("日本")).to eq(2)
          expect(mapper.length("😀")).to eq(2)
          expect(mapper.length("é")).to eq(2)
          expect(mapper.length(content)).to eq(7)
        end
      end

      it "slices only on exact Unicode scalar boundaries and rejects a split surrogate pair" do
        aggregate_failures do
          expect(mapper.byte_range_for_span(content, offset: 2, length: 2)).to eq(4...8)
          expect(mapper.slice(content, offset: 1, length: 1)).to eq("日")
          expect(mapper.slice(content, offset: 2, length: 2)).to eq("😀")
          expect(mapper.slice(content, offset: 4, length: 2)).to eq("é")
          expect(mapper.byte_range_for_span(content, offset: 3, length: 1)).to be_nil
          expect(mapper.slice(content, offset: 3, length: 1)).to be_nil
          expect(mapper.slice(content, offset: 2, length: 1)).to be_nil
        end
      end

      it "maps exact Ruby byte ranges back to UTF-16 provider spans" do
        aggregate_failures do
          expect(mapper.span_for_bytes(content, byte_offset: 4, byte_length: 4)).to eq(offset: 2, length: 2)
          expect(mapper.span_for_bytes(content, byte_offset: 8, byte_length: 3)).to eq(offset: 4, length: 2)
        end
      end
    end

    context "with textElements" do
      let(:index_type) { "textElements" }

      it "counts extended grapheme clusters without splitting emoji or combining sequences" do
        aggregate_failures do
          expect(mapper.length("ASCII")).to eq(5)
          expect(mapper.length("日本")).to eq(2)
          expect(mapper.length("😀")).to eq(1)
          expect(mapper.length("é")).to eq(1)
          expect(mapper.length("👩‍💻")).to eq(1)
          expect(mapper.length(content)).to eq(5)
        end
      end

      it "slices only on exact grapheme-cluster boundaries" do
        aggregate_failures do
          expect(mapper.byte_range_for_span(content, offset: 3, length: 1)).to eq(8...11)
          expect(mapper.slice(content, offset: 1, length: 1)).to eq("日")
          expect(mapper.slice(content, offset: 2, length: 1)).to eq("😀")
          expect(mapper.slice(content, offset: 3, length: 1)).to eq("é")
          expect(mapper.slice(content, offset: 5, length: 0)).to eq("")
        end
      end

      it "maps exact Ruby byte ranges back to text-element provider spans" do
        aggregate_failures do
          expect(mapper.span_for_bytes(content, byte_offset: 4, byte_length: 4)).to eq(offset: 2, length: 1)
          expect(mapper.span_for_bytes(content, byte_offset: 8, byte_length: 3)).to eq(offset: 3, length: 1)
        end
      end
    end
  end

  describe "fail-closed bounds" do
    subject(:mapper) { described_class.build(index_type: "textElements") }

    let(:content) { "A日😀" }

    it "rejects negative, non-integer, out-of-range, and oversized provider spans" do
      invalid_spans = [
        { offset: -1, length: 1 },
        { offset: 0, length: -1 },
        { offset: 0.0, length: 1 },
        { offset: 0, length: "1" },
        { offset: nil, length: 1 },
        { offset: 4, length: 0 },
        { offset: 3, length: 1 },
        { offset: described_class::MAX_PROVIDER_INDEX + 1, length: 0 },
        { offset: 0, length: described_class::MAX_PROVIDER_INDEX + 1 }
      ]

      expect(invalid_spans).to all(satisfy do |span|
        mapper.byte_range_for_span(content, **span).nil? && mapper.slice(content, **span).nil?
      end)
    end

    it "rejects malformed byte ranges and ranges that split encoded characters" do
      invalid_ranges = [
        { byte_offset: -1, byte_length: 1 },
        { byte_offset: 0, byte_length: -1 },
        { byte_offset: 0.0, byte_length: 1 },
        { byte_offset: 0, byte_length: "1" },
        { byte_offset: 2, byte_length: 1 },
        { byte_offset: content.bytesize + 1, byte_length: 0 },
        { byte_offset: 0, byte_length: described_class::MAX_PROVIDER_INDEX + 1 }
      ]

      expect(invalid_ranges).to all(satisfy do |range|
        mapper.span_for_bytes(content, **range).nil?
      end)
    end

    it "checks the byte bound before inspecting encoding and rejects invalid UTF-8" do
      oversized_string_class = Class.new(String) do
        def valid_encoding?
          raise "valid_encoding? must not inspect oversized provider content"
        end
      end
      oversized = oversized_string_class.new("A" * (described_class::MAX_CONTENT_BYTES + 1))
      invalid_utf8 = "\xFF".b.force_encoding(Encoding::UTF_8)

      aggregate_failures do
        expect(mapper.length(oversized)).to be_nil
        expect(mapper.slice(oversized, offset: 0, length: 1)).to be_nil
        expect(mapper.length(invalid_utf8)).to be_nil
        expect(mapper.slice(invalid_utf8, offset: 0, length: 1)).to be_nil
      end
    end

    it "does not mutate source text" do
      original = content.dup

      mapper.slice(content, offset: 0, length: 3)
      mapper.span_for_bytes(content, byte_offset: 0, byte_length: content.bytesize)

      expect(content).to eq(original)
    end

    it "reuses one bounded index for repeated spans instead of rescanning the whole provider text" do
      content = ("A" * 70_000).freeze

      Timeout.timeout(2) do
        4_800.times do |index|
          offset = 60_000 + (index % 9_000)
          expect(mapper.slice(content, offset:, length: 1)).to eq("A")
        end
      end
    end
  end
end
