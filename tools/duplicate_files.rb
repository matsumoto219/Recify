# frozen_string_literal: true

require "digest"
require "open3"
require "pathname"
require "set"

module DuplicateFiles
  class Error < StandardError; end
  class ScanError < Error; end
  class DetectedError < Error; end
  class UnsafeCleanupError < Error; end

  Entry = Struct.new(
    :path,
    :canonical_path,
    :state,
    :tracked,
    :canonical_tracked,
    keyword_init: true
  ) do
    def safe_to_delete?
      state == :identical && !tracked && canonical_tracked
    end
  end

  CleanupResult = Struct.new(
    :entries,
    :safe_paths,
    :unsafe_paths,
    :deleted_paths,
    keyword_init: true
  )

  class GitFileList
    def initialize(root:)
      @root = Pathname(root).expand_path
    end

    def tracked_paths
      run("ls-files", "-z", "--cached")
    end

    def untracked_paths
      run("ls-files", "-z", "--others", "--exclude-standard")
    end

    private

    attr_reader :root

    def run(*arguments)
      stdout, stderr, status = Open3.capture3("git", "-C", root.to_s, *arguments)
      unless status.success?
        message = stderr.strip
        message = "git #{arguments.join(' ')} failed" if message.empty?
        raise ScanError, message
      end

      stdout.split("\0").reject(&:empty?)
    end
  end

  class Scanner
    CONFLICTED_COPY_PATTERN = /\s+\([^)]*conflicted copy[^)]*\)(?=\..+\z|\z)/i
    PLAIN_CONFLICTED_COPY_PATTERN = /\s+conflicted copy(?: [^.]*)?(?=\..+\z|\z)/i
    COPY_PATTERN = / copy(?=\..+\z|\z)/i
    NUMBERED_COPY_PATTERN = / \d+(?=\..+\z|\z)/

    attr_reader :root

    def self.for_repository(root:)
      files = GitFileList.new(root: root)
      new(
        root: root,
        tracked_paths: files.tracked_paths,
        untracked_paths: files.untracked_paths
      )
    end

    def initialize(root:, tracked_paths:, untracked_paths:)
      @root = Pathname(root).expand_path
      @tracked_paths = normalize_paths(tracked_paths)
      @untracked_paths = normalize_paths(untracked_paths)
    end

    def call
      tracked = tracked_paths.to_set

      (tracked_paths + untracked_paths).uniq.filter_map do |path|
        canonical_path = canonical_path_for(path)
        next unless canonical_path
        next unless root.join(path).file?

        Entry.new(
          path: path,
          canonical_path: canonical_path,
          state: state_for(path, canonical_path),
          tracked: tracked.include?(path),
          canonical_tracked: tracked.include?(canonical_path)
        )
      end.sort_by(&:path)
    end

    private

    attr_reader :tracked_paths, :untracked_paths

    def normalize_paths(paths)
      Array(paths).map { |path| path.to_s.delete_prefix("./") }.reject(&:empty?).uniq
    end

    def canonical_path_for(path)
      basename = File.basename(path)
      canonical_basename = basename.sub(CONFLICTED_COPY_PATTERN, "")
      if canonical_basename == basename
        canonical_basename = canonical_basename.sub(PLAIN_CONFLICTED_COPY_PATTERN, "")
      end
      canonical_basename = canonical_basename.sub(COPY_PATTERN, "") if canonical_basename == basename
      canonical_basename = canonical_basename.sub(NUMBERED_COPY_PATTERN, "") if canonical_basename == basename
      return if canonical_basename == basename

      dirname = File.dirname(path)
      dirname == "." ? canonical_basename : File.join(dirname, canonical_basename)
    end

    def state_for(path, canonical_path)
      candidate = root.join(path)
      canonical = root.join(canonical_path)
      return :canonical_missing unless canonical.file?

      identical_content?(candidate, canonical) ? :identical : :different
    rescue SystemCallError
      :unreadable
    end

    def identical_content?(candidate, canonical)
      candidate.size == canonical.size &&
        Digest::SHA256.file(candidate).digest == Digest::SHA256.file(canonical).digest
    end
  end

  class Reporter
    STATE_LABELS = {
      identical: "byte-identical",
      different: "DIFFERENT CONTENT",
      canonical_missing: "CANONICAL MISSING",
      unreadable: "UNREADABLE"
    }.freeze

    def self.render(entries)
      lines = [ "Duplicate-like files detected (#{entries.size}):" ]
      entries.each do |entry|
        lines << format(
          "  %-18s %s -> %s",
          STATE_LABELS.fetch(entry.state, entry.state.to_s),
          entry.path,
          entry.canonical_path
        )
      end
      lines << "Run bin/cleanup_duplicate_files for a dry run."
      lines.join("\n")
    end
  end

  class Guard
    def initialize(scanner:)
      @scanner = scanner
    end

    def verify!
      entries = scanner.call
      raise DetectedError, Reporter.render(entries) if entries.any?

      entries
    end

    private

    attr_reader :scanner
  end

  class Cleaner
    def initialize(scanner:)
      @scanner = scanner
    end

    def call(apply: false)
      entries = scanner.call
      safe_entries = entries.select(&:safe_to_delete?)
      unsafe_entries = entries.reject(&:safe_to_delete?)

      if apply && unsafe_entries.any?
        raise UnsafeCleanupError,
              "Cleanup aborted before deletion because unsafe candidates exist.\n#{Reporter.render(unsafe_entries)}"
      end

      deleted_paths = apply ? delete_verified_entries(safe_entries) : []

      CleanupResult.new(
        entries: entries,
        safe_paths: safe_entries.map(&:path),
        unsafe_paths: unsafe_entries.map(&:path),
        deleted_paths: deleted_paths
      )
    end

    private

    attr_reader :scanner

    def delete_verified_entries(entries)
      refreshed_entries = scanner.call.to_h { |entry| [ entry.path, entry ] }
      unless entries.all? { |entry| refreshed_entries[entry.path]&.safe_to_delete? }
        raise UnsafeCleanupError, "Cleanup aborted because files changed after the initial scan."
      end

      entries.each do |entry|
        File.delete(scanner.root.join(entry.path))
      end
      entries.map(&:path)
    end
  end

  class FileProviderDetector
    FILE_PROVIDER_ATTRIBUTE = "com.apple.file-provider-domain-id"

    def initialize(root:, platform: RUBY_PLATFORM, file_provider_probe: nil)
      @root = Pathname(root).expand_path
      @platform = platform
      @file_provider_probe = file_provider_probe || method(:file_provider?)
    end

    def call
      return unless platform.include?("darwin")

      root.ascend do |path|
        return path.to_s if file_provider_probe.call(path.to_s)
      end
      nil
    end

    private

    attr_reader :root, :platform, :file_provider_probe

    def file_provider?(path)
      _stdout, _stderr, status = Open3.capture3(
        "xattr",
        "-p",
        FILE_PROVIDER_ATTRIBUTE,
        path
      )
      status.success?
    rescue Errno::ENOENT
      false
    end
  end

  def self.verify_repository!(root:)
    Guard.new(scanner: Scanner.for_repository(root: root)).verify!
  end
end
