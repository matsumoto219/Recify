# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../../tools/duplicate_files"

RSpec.describe DuplicateFiles do
  def write_file(root, relative_path, content)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def build_scanner(root:, tracked_paths:, untracked_paths:)
    DuplicateFiles::Scanner.new(
      root: root,
      tracked_paths: tracked_paths,
      untracked_paths: untracked_paths
    )
  end

  around do |example|
    Dir.mktmpdir("duplicate-files-spec") do |root|
      @root = root
      example.run
    end
  end

  it "classifies a numbered byte-identical sibling as safe to delete" do
    write_file(@root, "app/example.rb", "same\n")
    write_file(@root, "app/example 2.rb", "same\n")

    entry = build_scanner(
      root: @root,
      tracked_paths: [ "app/example.rb" ],
      untracked_paths: [ "app/example 2.rb" ]
    ).call.fetch(0)

    aggregate_failures do
      expect(entry.path).to eq("app/example 2.rb")
      expect(entry.canonical_path).to eq("app/example.rb")
      expect(entry.state).to eq(:identical)
      expect(entry).to be_safe_to_delete
    end
  end

  it "recognizes copy and conflicted-copy filename variants" do
    write_file(@root, "config/settings.yml", "same\n")
    write_file(@root, "config/settings copy.yml", "same\n")
    write_file(@root, "spec/example.rb", "same\n")
    write_file(@root, "spec/example (Mac's conflicted copy 2026-07-12).rb", "same\n")
    write_file(@root, "spec/plain.rb", "same\n")
    write_file(@root, "spec/plain conflicted copy 2026-07-12.rb", "same\n")

    entries = build_scanner(
      root: @root,
      tracked_paths: [ "config/settings.yml", "spec/example.rb", "spec/plain.rb" ],
      untracked_paths: [
        "config/settings copy.yml",
        "spec/example (Mac's conflicted copy 2026-07-12).rb",
        "spec/plain conflicted copy 2026-07-12.rb"
      ]
    ).call

    expect(entries.map { |entry| [ entry.path, entry.canonical_path, entry.state ] }).to contain_exactly(
      [ "config/settings copy.yml", "config/settings.yml", :identical ],
      [ "spec/example (Mac's conflicted copy 2026-07-12).rb", "spec/example.rb", :identical ],
      [ "spec/plain conflicted copy 2026-07-12.rb", "spec/plain.rb", :identical ]
    )
  end

  it "never marks divergent or canonical-missing files as safe" do
    write_file(@root, "app/example.rb", "canonical\n")
    write_file(@root, "app/example 2.rb", "different\n")
    write_file(@root, "app/orphan 2.rb", "orphan\n")

    entries = build_scanner(
      root: @root,
      tracked_paths: [ "app/example.rb" ],
      untracked_paths: [ "app/example 2.rb", "app/orphan 2.rb" ]
    ).call

    aggregate_failures do
      expect(entries.map(&:state)).to contain_exactly(:different, :canonical_missing)
      expect(entries).to all(satisfy { |entry| !entry.safe_to_delete? })
    end
  end

  it "does not delete anything during the default dry run" do
    write_file(@root, "app/example.rb", "same\n")
    duplicate_path = write_file(@root, "app/example 2.rb", "same\n")
    scanner = build_scanner(
      root: @root,
      tracked_paths: [ "app/example.rb" ],
      untracked_paths: [ "app/example 2.rb" ]
    )

    result = DuplicateFiles::Cleaner.new(scanner: scanner).call

    aggregate_failures do
      expect(result.deleted_paths).to eq([])
      expect(result.safe_paths).to eq([ "app/example 2.rb" ])
      expect(File).to exist(duplicate_path)
    end
  end

  it "deletes only a byte-identical untracked sibling when apply is explicit" do
    write_file(@root, "app/example.rb", "same\n")
    duplicate_path = write_file(@root, "app/example 2.rb", "same\n")
    scanner = build_scanner(
      root: @root,
      tracked_paths: [ "app/example.rb" ],
      untracked_paths: [ "app/example 2.rb" ]
    )

    result = DuplicateFiles::Cleaner.new(scanner: scanner).call(apply: true)

    aggregate_failures do
      expect(result.deleted_paths).to eq([ "app/example 2.rb" ])
      expect(File).not_to exist(duplicate_path)
      expect(File).to exist(File.join(@root, "app/example.rb"))
    end
  end

  it "aborts the whole apply before deletion when any candidate is unsafe" do
    write_file(@root, "app/safe.rb", "same\n")
    safe_duplicate = write_file(@root, "app/safe 2.rb", "same\n")
    write_file(@root, "app/unsafe.rb", "canonical\n")
    unsafe_duplicate = write_file(@root, "app/unsafe 2.rb", "different\n")
    scanner = build_scanner(
      root: @root,
      tracked_paths: [ "app/safe.rb", "app/unsafe.rb" ],
      untracked_paths: [ "app/safe 2.rb", "app/unsafe 2.rb" ]
    )

    expect do
      DuplicateFiles::Cleaner.new(scanner: scanner).call(apply: true)
    end.to raise_error(DuplicateFiles::UnsafeCleanupError)

    aggregate_failures do
      expect(File).to exist(safe_duplicate)
      expect(File).to exist(unsafe_duplicate)
    end
  end

  it "reports all suspicious files before tests or validators continue" do
    write_file(@root, "db/migrate/example.rb", "same\n")
    write_file(@root, "db/migrate/example 2.rb", "same\n")
    scanner = build_scanner(
      root: @root,
      tracked_paths: [ "db/migrate/example.rb" ],
      untracked_paths: [ "db/migrate/example 2.rb" ]
    )

    expect do
      DuplicateFiles::Guard.new(scanner: scanner).verify!
    end.to raise_error(
      DuplicateFiles::DetectedError,
      a_string_including("db/migrate/example 2.rb", "byte-identical", "bin/cleanup_duplicate_files")
    )
  end

  it "detects a macOS File Provider-managed ancestor" do
    provider_root = File.dirname(@root)
    detector = DuplicateFiles::FileProviderDetector.new(
      root: @root,
      platform: "arm64-darwin",
      file_provider_probe: ->(path) { path == provider_root }
    )

    expect(detector.call).to eq(provider_root)
  end
end
