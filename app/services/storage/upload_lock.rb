require "digest"
require "fileutils"

module Storage
  class UploadLock
    BUCKETS = 256
    NAMESPACES = %w[images registrations].freeze

    def self.call(key:, namespace:)
      service = ActiveStorage::Blob.service
      raise ArgumentError, "unsupported upload storage" unless service.is_a?(ActiveStorage::Service::DiskService)
      raise ArgumentError, "unsupported upload lock" unless NAMESPACES.include?(namespace)

      directory = File.join(service.root, ".upload-locks", namespace)
      FileUtils.mkdir_p(directory)
      bucket = Digest::SHA256.hexdigest(key.to_s).to_i(16) % BUCKETS
      # Fixed lock files are never unlinked: replacing an inode would split the lock.
      File.open(File.join(directory, bucket.to_s), File::RDWR | File::CREAT, 0o600) do |file|
        return unless file.flock(File::LOCK_EX | File::LOCK_NB)

        begin
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end
  end
end
