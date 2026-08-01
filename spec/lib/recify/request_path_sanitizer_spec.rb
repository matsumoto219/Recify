require "rails_helper"

RSpec.describe Recify::RequestPathSanitizer do
  it "単に長いscanner pathや正規routeをsecret扱いしない" do
    paths = [
      "/#{'a' * 48}.php",
      "/admin/receipt_analysis_runs/123e4567-e89b-12d3-a456-426614174000",
      "/settings/security/recovery_codes/regenerate"
    ]

    aggregate_failures do
      paths.each { |path| expect(described_class.sanitize(path)).to eq(path) }
    end
  end

  it "URLのuserinfo、query、fragmentを除去してpathを維持する" do
    value = "https://user:pass@example.test/admin/events?token=secret#fragment"

    expect(described_class.sanitize(value)).to eq("https://example.test/admin/events")
  end

  it "Active Storage capability pathを全体redactする" do
    value = "https://example.test/rails/active_storage/blobs/redirect/signed-capability/file.png"

    expect(described_class.sanitize(value)).to eq(Recify::ActiveStorageLogRedactor::FILTERED_URL)
  end

  it "明示secret、email、control characterをpathから除去する" do
    value = "/person@example.test/token=secret\nnext\0"
    sanitized = described_class.sanitize(value)

    aggregate_failures do
      expect(sanitized).to include(described_class::REDACTED_EMAIL, "token=#{described_class::FILTERED_VALUE}")
      expect(sanitized).to include("\\n")
      expect(sanitized).not_to include("person@example.test", "secret", "\n", "\0")
    end
  end

  it "invalid encodingを例外なく処理しpath上限で打ち切る" do
    invalid = ("/safe/" + ("a" * 3_000)).b
    invalid.setbyte(2, 0xFF)

    sanitized = nil
    expect { sanitized = described_class.sanitize(invalid) }.not_to raise_error

    aggregate_failures do
      expect(sanitized).to be_valid_encoding
      expect(sanitized.length).to eq(described_class::MAX_LENGTH)
    end
  end

  it "極端に長い入力も固定したprocessing上限内で処理する" do
    oversized = "https://user:pass@example.test/#{'a' * 100_000}?token=secret"
    sanitized = described_class.sanitize(oversized)

    aggregate_failures do
      expect(sanitized.length).to eq(described_class::MAX_LENGTH)
      expect(sanitized).to start_with("https://example.test/")
      expect(sanitized).not_to include("user:pass@", "token=secret")
    end
  end
end
