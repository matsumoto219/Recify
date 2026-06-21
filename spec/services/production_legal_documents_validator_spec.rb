# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProductionLegalDocumentsValidator do
  def fake_verifier(error: nil)
    Class.new do
      attr_reader :calls

      define_method(:initialize) do
        @error = error
        @calls = []
      end

      def verify_files!
        calls << :files
        raise error if error

        true
      end

      def verify_database!
        calls << :database
        raise error if error

        true
      end

      private

      attr_reader :error
    end.new
  end

  it "DB不要のYAML検証を実行する" do
    verifier = fake_verifier
    result = described_class.call(database: false, verifier: verifier)

    aggregate_failures do
      expect(result).to be_success
      expect(verifier.calls).to eq([ :files ])
    end
  end

  it "DBありの同期検証を実行する" do
    verifier = fake_verifier
    result = described_class.call(database: true, verifier: verifier)

    aggregate_failures do
      expect(result).to be_success
      expect(verifier.calls).to eq([ :database ])
    end
  end

  it "YAML検証エラーを短い安全な項目へ変換する" do
    verifier = fake_verifier(error: LegalDocuments::ValidationError.new(
      "#{Rails.root}/config/legal_documents/current.yml missing\n"
    ))

    result = described_class.call(database: false, verifier: verifier)

    aggregate_failures do
      expect(result).not_to be_success
      expect(result.missing_items).to contain_exactly(
        "legal_documents.files: [APP_ROOT]/config/legal_documents/current.yml missing"
      )
    end
  end

  it "DB検証エラーをvalidator例外へ変換する" do
    verifier = fake_verifier(error: LegalDocuments::ValidationError.new("DB current terms/ja count is 0"))

    expect do
      described_class.validate!(database: true, verifier: verifier)
    end.to raise_error(described_class::ValidationError) { |error|
      expect(error.message).to include("legal_documents.database")
      expect(error.message).to include("DB current terms/ja count is 0")
    }
  end
end
