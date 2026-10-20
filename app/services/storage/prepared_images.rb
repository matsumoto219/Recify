module Storage
  class PreparedImages
    METADATA_KEY = "upload_preparation"
    RETENTION = 24.hours
    MAX_RECORDS = 20

    Entry = Data.define(:record, :blob, :io, :old_attachment_id, :old_blob)
    private_constant :Entry

    def self.call(records:, attachment_name:, user: nil, registration_key: nil, &operation)
      new(records:, attachment_name:, user:, registration_key:).call(&operation)
    end

    def initialize(records:, attachment_name:, user:, registration_key:)
      @records = records
      @attachment_name = attachment_name.to_s
      @user = user
      @registration_key = registration_key
      @attempt = SecureRandom.hex(32)
      @entries = []
    end

    def call
      raise ArgumentError, "invalid image preparation" unless records.is_a?(Array) && records.size.between?(1, MAX_RECORDS)
      if registration_key && !(user && registration_key.is_a?(String) && registration_key.match?(/\A[0-9a-f]{64}\z/))
        raise ArgumentError, "invalid registration identity"
      end
      return false unless records.map(&:valid?).all?
      return false unless build_entries

      result = UploadLock.call(key: attempt, namespace: "images") do
        reserve!
        next false unless upload_images

        accept { yield }
      ensure
        discard_unaccepted
      end
      accepted = result == true
      result.nil? ? upload_failure(:upload_in_progress) : result
    ensure
      restore_attachments unless accepted
    end

    private

    attr_reader :records, :attachment_name, :user, :attempt, :entries, :registration_key

    def build_entries
      records.each do |record|
        change = record.attachment_changes.fetch(attachment_name)
        blob = record.public_send(attachment_name).blob
        io = upload_io(change.attachable)
        max_bytes, max_dimension = image_limits(record)
        # Keep BMP compatibility until its planned deprecation. Rails blocks its untrusted decoder;
        # existing format/dimension checks do not guarantee full-image readability.
        error = if !io
          :unreadable_image
        elsif blob.content_type != "image/bmp"
          ImageReadability.validation_error(io:, content_type: blob.content_type, max_bytes:, max_dimension:)
        end
        if error
          record.errors.add(attachment_name, error)
          return false
        end

        dimensions = ImageDimensions.extract(blob:, attached_change: change)
        old_attachment = record.persisted? ? ActiveStorage::Attachment.find_by(record:, name: attachment_name) : nil
        blob.metadata = {
          "identified" => true,
          "analyzed" => true,
          "width" => dimensions.fetch(:width),
          "height" => dimensions.fetch(:height),
          METADATA_KEY => {
            "attempt" => attempt,
            "user_id" => user&.id,
            "registration_key" => registration_key,
            "expires_at" => RETENTION.from_now.utc.iso8601
          }
        }
        entries << Entry.new(record:, blob:, io:, old_attachment_id: old_attachment&.id, old_blob: old_attachment&.blob)
      end
      true
    end

    def image_limits(record)
      case record
      when Receipt then [ Receipt.image_max_file_size, Receipt.image_max_dimension ]
      when User then [ User.avatar_max_file_size, Receipt.image_max_dimension ]
      when Announcement then [ Announcement.image_max_file_size, Announcement.image_max_dimension ]
      else raise ArgumentError, "unsupported image owner"
      end
    end

    def upload_io(attachable)
      return attachable[:io] if attachable.is_a?(Hash)
      return attachable.tempfile if attachable.respond_to?(:tempfile)

      attachable.to_io if attachable.respond_to?(:to_io)
    end

    def reserve!
      QuotaReservation.call(byte_size: entries.sum { |entry| entry.blob.byte_size }) do
        verify_user_quota!
        entries.each { |entry| entry.blob.save! }
      end
    end

    def upload!(entry)
      entry.io.rewind
      entry.blob.upload_without_unfurling(entry.io)
      entry.record.public_send("#{attachment_name}=", entry.blob)
    ensure
      entry.io.rewind
    end

    def upload_images
      entries.each { |entry| upload!(entry) }
      true
    rescue IOError, SystemCallError, ActiveStorage::IntegrityError
      upload_failure
    end

    def upload_failure(error = :upload_failed)
      records.each { |record| record.errors.add(attachment_name, error) }
      false
    end

    def accept
      saved = false
      QuotaReservation.call(byte_size: 0) do
        verify_user_quota!(reserved: true)
        entries.each { |entry| verify_destination!(entry) }
        ActiveRecord::Base.transaction(requires_new: true) do
          saved = yield
          raise ActiveRecord::Rollback unless saved

          entries.each do |entry|
            raise ActiveRecord::RecordNotSaved, "prepared image not attached" unless entry.blob.attachments.exists?

            entry.blob.update_columns(metadata: entry.blob.metadata.except(METADATA_KEY))
          end
        end
      end
      saved
    end

    def verify_destination!(entry)
      return unless entry.record.persisted?

      entry.record.class.lock.find(entry.record.id)
      current_id = ActiveStorage::Attachment.find_by(record: entry.record, name: attachment_name)&.id
      return if current_id == entry.old_attachment_id

      raise ActiveRecord::StaleObjectError.new(entry.record, "update")
    end

    def verify_user_quota!(reserved: false)
      return unless user

      locked_user = User.lock.find(user.id)
      calculator = UsageCalculator.new(locked_user)
      reservation_scope = PreparedImageCleanup.scope.where("metadata::jsonb -> ? ->> 'user_id' = ?", METADATA_KEY, user.id.to_s)
      pending_bytes = reservation_scope.sum(:byte_size)
      new_bytes = reserved ? 0 : entries.sum { |entry| entry.blob.byte_size }
      old_bytes = entries.filter_map(&:old_blob).uniq(&:id).sum(&:byte_size)
      return if calculator.used_bytes - old_bytes + pending_bytes + new_bytes <= calculator.limit_bytes

      raise QuotaExceeded.new(scope: :user)
    end

    def discard_unaccepted
      entries.each do |entry|
        PreparedImageCleanup.discard(entry.blob.id, attempt:) if entry.blob.id
      rescue StandardError => error
        Rails.logger.warn("[Storage] prepared_image_cleanup_failed error_class=#{error.class}")
      end
    end

    def restore_attachments
      return unless records.is_a?(Array)

      ActiveRecord::Base.connection_pool.clear_query_cache
      records.each do |record|
        record.attachment_changes.delete(attachment_name)
        %w[attachment blob].each do |suffix|
          association = record.association("#{attachment_name}_#{suffix}".to_sym)
          association.reset
          association.reset_scope
        end
      end
    end
  end
end
