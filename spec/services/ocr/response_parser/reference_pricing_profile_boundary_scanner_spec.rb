require "rails_helper"
require "fileutils"
require "tmpdir"
require_relative "../../../support/reference_pricing_profile_boundary_scanner"

RSpec.describe ReferencePricingProfileBoundary::Scanner do
  def with_scanner(files)
    Dir.mktmpdir("reference-pricing-profile-boundary-", Rails.root.join("tmp").to_s) do |directory|
      root = Pathname(directory)
      files.each do |relative_path, source|
        path = root.join(relative_path)
        FileUtils.mkdir_p(path.dirname)
        path.write(source)
      end

      yield described_class.new(root:)
    end
  end

  it "国別語彙・script制約・Japan profile直接参照を検知する" do
    with_scanner(
      "app/services/ocr/response_parser/reference_pricing_candidate_extractor.rb" => <<~RUBY
        TOTAL_PATTERN = /合計/
        ESCAPED_TOTAL_PATTERN = /\\u{5408}\\u{8A08}/
        MINIMUM_PATTERN = /at\\s+least/
        IDENTIFIER_PATTERN = /\\p{Han}/
        ARABIC_PATTERN = /\\p{Arabic}/
        PROFILE_PATTERN = ReceiptAnalysisProfiles::Japan::OCR_TOTAL_AMOUNT_LINE_PATTERN
        PROFILE = ReceiptAnalysisProfiles.fetch("JPN")
      RUBY
    ) do |scanner|
      aggregate_failures do
        expect(scanner.issues).to be_empty
        expect(scanner.violations.map(&:kind).tally).to eq(
          country_specific_literal: 5,
          direct_country_profile_reference: 1,
          direct_country_profile_lookup: 1
        )
      end
    end
  end

  it "数値・通貨表記・provider field名・commentを共有構造として許可する" do
    with_scanner(
      "app/services/ocr/response_parser/reference_pricing_line_group_extractor.rb" => <<~RUBY
        # 小計はprofile側で所有する
        AMOUNT_PATTERN = /[0-9¥￥$€£]|円/
        GENERIC_UNICODE_PATTERN = /[\\p{L}\\p{N}\\p{Zs}\\p{P}\\p{Bidi_Control}]/
        PROVIDER_FIELDS = %w[Total TotalPrice]
      RUBY
    ) do |scanner|
      aggregate_failures do
        expect(scanner.issues).to be_empty
        expect(scanner.violations).to be_empty
      end
    end
  end

  it "将来追加されたreference pricing extractorも対象にする" do
    with_scanner(
      "app/services/ocr/response_parser/reference_pricing_tax_extractor.rb" => "PATTERN = /subtotal/\n"
    ) do |scanner|
      expect(scanner.violations.sole).to have_attributes(kind: :country_specific_literal)
    end
  end

  it "Rubyとしてparseできない対象をissueにする" do
    with_scanner(
      "app/services/ocr/response_parser/reference_pricing_candidate_extractor.rb" => "def broken(\n"
    ) do |scanner|
      aggregate_failures do
        expect(scanner.issues).not_to be_empty
        expect(scanner.violations).to be_empty
      end
    end
  end

  it "対象extractorが0件ならissueにする" do
    with_scanner("unrelated.rb" => "VALUE = 1\n") do |scanner|
      aggregate_failures do
        expect(scanner.issues.sole.message).to eq("no reference pricing extractor targets found")
        expect(scanner.violations).to be_empty
        expect(scanner.scanned_paths).to be_empty
      end
    end
  end
end
