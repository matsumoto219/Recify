module LegalDocuments
  class Sync
    Result = Struct.new(:created, :updated, :current, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(repository: Repository.new, dry_run: false, allow_rewrite: ENV["ALLOW_LEGAL_DOCUMENT_REWRITE"] == "true")
      @repository = repository
      @dry_run = dry_run
      @allow_rewrite = allow_rewrite
      @created = []
      @updated = []
      @current = []
    end

    def call
      repository.verify_files!

      if dry_run
        inspect_changes
      else
        sync_documents!
      end

      Result.new(created: created, updated: updated, current: current)
    end

    private

    attr_reader :repository, :dry_run, :allow_rewrite, :created, :updated, :current

    def inspect_changes
      repository.all.each do |document|
        record = find_record(document)
        if record.blank?
          created << document.identity
        elsif attributes_changed?(record, document)
          updated << document.identity
        end
      end

      repository.current_documents.each { |document| current << document.identity }
    end

    def sync_documents!
      LegalDocument.transaction do
        repository.all.each { |document| sync_document!(document) }
        sync_current_documents!
      end
    end

    def sync_document!(document)
      record = find_record(document)
      expected_current = repository.current_document?(document)
      attributes = document.attributes_for_database(current: false)

      if record.blank?
        LegalDocument.create!(attributes)
        created << document.identity
        return
      end

      ensure_rewrite_allowed!(record, document)
      attributes[:current] = expected_current if record.current? && expected_current

      return unless attributes_changed?(record, document)

      record.update!(attributes)
      updated << document.identity
    end

    def sync_current_documents!
      pairs = repository.all.map(&:current_key).uniq

      pairs.each do |document_type, locale|
        LegalDocument.where(document_type: document_type, locale: locale, current: true)
                     .update_all(current: false, updated_at: Time.current)
      end

      repository.current_documents.each do |document|
        record = find_record(document)
        record.update!(current: true) unless record.current?
        current << document.identity
      end
    end

    def ensure_rewrite_allowed!(record, document)
      return if record.content_digest == document.content_digest
      return if allow_rewrite && record.legal_acceptances.none?

      raise SyncError, "#{record.source_path} content changed after synchronization"
    end

    def attributes_changed?(record, document)
      attributes = document.attributes_for_database(current: repository.current_document?(document))

      attributes.any? do |attribute, expected_value|
        record.public_send(attribute) != expected_value
      end
    end

    def find_record(document)
      LegalDocument.find_by(
        document_type: document.document_type,
        version: document.version,
        locale: document.locale
      )
    end
  end
end
