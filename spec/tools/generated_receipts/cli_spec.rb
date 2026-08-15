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

  it "fails closed with a generic message when a fixture cannot be loaded safely" do
    unsafe_path = "/tmp/private\nfixture.json"
    allow(DuplicateFiles).to receive(:verify_repository!).and_return(true)
    allow(GeneratedReceipts).to receive(:case_paths).and_return([ unsafe_path ])
    allow(GeneratedReceipts::Validator).to receive(:load_file).and_raise(
      GeneratedReceipts::Validator::FixtureLoadError,
      GeneratedReceipts::Validator::FIXTURE_LOAD_ERROR_MESSAGE
    )

    expect do
      described_class.call([])
    end.to output(
      a_string_matching(/\A(?=.*FAIL generated receipt fixture)(?!.*private).*\z/m)
    ).to_stdout.and raise_error(SystemExit)
  end
end
