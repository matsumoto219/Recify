require "yaml"

module LegalDocuments
  class Repository
    ROOT = Rails.root.join("config/legal_documents")
    CURRENT_PATH = ROOT.join("current.yml")
    CURRENT_KEYS = %w[terms privacy].freeze

    def all
      @all ||= document_paths.map { |path| load_document(path) }
    end

    def find(document_type:, version:, locale: "ja")
      all.find do |document|
        document.document_type == document_type.to_s &&
          document.version == version.to_s &&
          document.locale == locale.to_s
      end
    end

    def find!(document_type:, version:, locale: "ja")
      find(document_type: document_type, version: version, locale: locale) ||
        raise(ValidationError, "Legal document #{document_type}/#{version}/#{locale} was not found")
    end

    def current(document_type:, locale: "ja")
      version = current_versions.dig(document_type.to_s, locale.to_s)
      return nil if version.blank?

      find(document_type: document_type, version: version, locale: locale)
    end

    def current!(document_type:, locale: "ja")
      current(document_type: document_type, locale: locale) ||
        raise(ValidationError, "Current legal document #{document_type}/#{locale} was not found")
    end

    def current_documents
      current_versions.flat_map do |document_type, versions_by_locale|
        versions_by_locale.map do |locale, version|
          find!(document_type: document_type, version: version, locale: locale)
        end
      end
    end

    def current_document?(document)
      current_versions.dig(document.document_type, document.locale) == document.version
    end

    def current_versions
      @current_versions ||= begin
        data = load_yaml(CURRENT_PATH)
        current = data["current"]
        unless current.is_a?(Hash)
          raise ValidationError, "#{relative_path(CURRENT_PATH)} must contain current mapping"
        end

        current.deep_stringify_keys
      end
    end

    def verify_files!
      documents_by_identity = {}

      all.each do |document|
        if documents_by_identity.key?(document.identity)
          raise ValidationError, "Duplicate legal document #{document.identity.join('/')}"
        end

        documents_by_identity[document.identity] = document
      end

      CURRENT_KEYS.each do |document_type|
        versions_by_locale = current_versions[document_type]
        unless versions_by_locale.is_a?(Hash) && versions_by_locale["ja"].present?
          raise ValidationError, "#{relative_path(CURRENT_PATH)} must define current #{document_type}.ja"
        end
      end

      current_documents.each do |document|
        unless document.status == "published"
          raise ValidationError, "Current legal document #{document.identity.join('/')} must be published"
        end
      end

      true
    end

    private

    def document_paths
      Dir.glob(ROOT.join("*/*.yml").to_s).sort.map { |path| Pathname(path) }
    end

    def load_document(path)
      FileDocument.new(source_path: relative_path(path), data: load_yaml(path))
    end

    def load_yaml(path)
      YAML.safe_load(File.read(path), aliases: false) || {}
    rescue Errno::ENOENT
      raise ValidationError, "#{relative_path(path)} was not found"
    rescue Psych::Exception => e
      raise ValidationError, "#{relative_path(path)} is invalid YAML: #{e.message}"
    end

    def relative_path(path)
      Pathname(path).relative_path_from(Rails.root).to_s
    end
  end
end
