module LegalDocuments
  class << self
    def current_status(locale: I18n.locale)
      CurrentStatus.call(locale: locale)
    end

    def synchronized_file_for!(legal_document:)
      file_document = Repository.new.find!(
        document_type: legal_document.document_type,
        version: legal_document.version,
        locale: legal_document.locale
      )
      return file_document if file_document.source_path == legal_document.source_path &&
                              file_document.content_digest == legal_document.content_digest

      raise ValidationError, "Legal document #{legal_document.source_path} is not synchronized"
    end

    def sync(...)
      Sync.call(...)
    end

    def verify_files!(...)
      Verifier.verify_files!(...)
    end

    def verify_database!(...)
      Verifier.verify_database!(...)
    end
  end
end
