# frozen_string_literal: true

require_relative "../../../tools/duplicate_files"
require_relative "../../../tools/generated_receipts/cli"

RSpec.describe GeneratedReceipts::Cli do
  it "stops with the duplicate-file report before validating case counts" do
    allow(DuplicateFiles).to receive(:verify_repository!).and_raise(
      DuplicateFiles::DetectedError,
      "Duplicate-like files detected: g112 2.json\nRun bin/cleanup_duplicate_files"
    )

    expect do
      described_class.call([])
    end.to output(
      a_string_including("Duplicate-like files detected", "bin/cleanup_duplicate_files")
    ).to_stderr.and raise_error(SystemExit)
  end
end
