require "set"

module LegalDocuments
  class Verifier
    def self.verify_files!(...)
      new(...).verify_files!
    end

    def self.verify_database!(...)
      new(...).verify_database!
    end

    def initialize(repository: Repository.new)
      @repository = repository
      @errors = []
    end

    def verify_files!
      repository.verify_files!
    end

    def verify_database!
      repository.verify_files!
      verify_yaml_documents_exist_in_database
      verify_database_documents_exist_in_yaml
      verify_current_documents
      raise_if_errors!

      true
    end

    private

    attr_reader :repository, :errors

    def verify_yaml_documents_exist_in_database
      repository.all.each do |document|
        record = legal_document_record(document)
        if record.blank?
          errors << "Missing DB legal document #{document.identity.join('/')}"
          next
        end

        compare_record_with_file(record, document)
      end
    end

    def verify_database_documents_exist_in_yaml
      source_paths = repository.all.map(&:source_path).to_set

      LegalDocument.find_each do |record|
        next if source_paths.include?(record.source_path)

        errors << "DB legal document #{record.source_path} is not present in YAML"
      end
    end

    def verify_current_documents
      repository.current_versions.each do |document_type, versions_by_locale|
        versions_by_locale.each_key do |locale|
          count = LegalDocument.where(document_type: document_type, locale: locale, current: true).count
          errors << "DB current #{document_type}/#{locale} count is #{count}" unless count == 1

          record = LegalDocument.find_by(document_type: document_type, locale: locale, current: true)
          expected = repository.current!(document_type: document_type, locale: locale)
          next if record&.version == expected.version

          errors << "DB current #{document_type}/#{locale} is #{record&.version.inspect}, expected #{expected.version.inspect}"
        end
      end
    end

    def compare_record_with_file(record, document)
      expected_attributes = document.attributes_for_database(current: repository.current_document?(document))

      expected_attributes.each do |attribute, expected_value|
        actual_value = record.public_send(attribute)
        next if actual_value == expected_value

        errors << "#{record.source_path} #{attribute} is #{actual_value.inspect}, expected #{expected_value.inspect}"
      end
    end

    def legal_document_record(document)
      LegalDocument.find_by(
        document_type: document.document_type,
        version: document.version,
        locale: document.locale
      )
    end

    def raise_if_errors!
      return if errors.empty?

      raise ValidationError, errors.join("\n")
    end
  end
end
