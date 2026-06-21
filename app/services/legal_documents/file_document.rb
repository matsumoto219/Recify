require "digest"
require "json"

module LegalDocuments
  class FileDocument
    DOCUMENT_TYPES = %w[terms privacy].freeze
    STATUSES = %w[draft published archived].freeze
    VERSION_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
    SOURCE_PATH_FORMAT = %r{\Aconfig/legal_documents/(?<document_type>terms|privacy)/(?<version>\d{4}-\d{2}-\d{2})\.(?<locale>[a-z]{2})\.yml\z}
    REQUIRED_KEYS = %w[
      document_type
      version
      locale
      title
      meta_description
      lead
      published_on
      effective_on
      last_updated_on
      reconsent_required
      status
      sections
    ].freeze

    attr_reader :source_path,
                :data,
                :document_type,
                :version,
                :locale,
                :title,
                :meta_description,
                :lead,
                :published_on,
                :effective_on,
                :last_updated_on,
                :reconsent_required,
                :status,
                :sections

    def initialize(source_path:, data:)
      @source_path = source_path.to_s
      @data = stringify_hash(data)

      validate_required_keys!

      @document_type = string_value("document_type")
      @version = string_value("version")
      @locale = string_value("locale")
      @title = string_value("title")
      @meta_description = string_value("meta_description")
      @lead = string_value("lead")
      @published_on = date_value("published_on")
      @effective_on = date_value("effective_on")
      @last_updated_on = date_value("last_updated_on")
      @reconsent_required = boolean_value("reconsent_required")
      @status = string_value("status")
      @sections = @data.fetch("sections")

      validate!
    end

    def identity
      [ document_type, version, locale ]
    end

    def current_key
      [ document_type, locale ]
    end

    def content_digest
      @content_digest ||= Digest::SHA256.hexdigest(JSON.generate(normalize_for_digest(data)))
    end

    def attributes_for_database(current:)
      {
        document_type: document_type,
        version: version,
        locale: locale,
        title: title,
        source_path: source_path,
        effective_on: effective_on,
        published_on: published_on,
        last_updated_on: last_updated_on,
        reconsent_required: reconsent_required,
        current: current,
        status: status,
        content_digest: content_digest
      }
    end

    private

    def stringify_hash(value)
      unless value.is_a?(Hash)
        raise ValidationError, "#{source_path} must contain a YAML mapping"
      end

      value.deep_stringify_keys
    end

    def validate_required_keys!
      missing_keys = REQUIRED_KEYS.reject { |key| data.key?(key) }
      return if missing_keys.empty?

      raise ValidationError, "#{source_path} is missing keys: #{missing_keys.join(', ')}"
    end

    def validate!
      validate_source_path!
      validate_value!(DOCUMENT_TYPES.include?(document_type), "document_type must be terms or privacy")
      validate_value!(version.match?(VERSION_FORMAT), "version must be YYYY-MM-DD")
      validate_value!(locale.match?(/\A[a-z]{2}\z/), "locale must be a two-letter code")
      validate_value!(STATUSES.include?(status), "status must be draft, published, or archived")
      validate_value!(sections.is_a?(Array) && sections.present?, "sections must be a non-empty array")
      sections.each.with_index(1) { |section, index| validate_section!(section, index) }
    end

    def validate_source_path!
      match = source_path.match(SOURCE_PATH_FORMAT)
      unless match
        raise ValidationError, "#{source_path} must match config/legal_documents/{type}/{version}.{locale}.yml"
      end

      %w[document_type version locale].each do |key|
        expected_value = match[key]
        actual_value = public_send(key)
        next if actual_value == expected_value

        raise ValidationError, "#{source_path} has #{key}=#{actual_value.inspect}, expected #{expected_value.inspect}"
      end
    end

    def validate_section!(section, index)
      unless section.is_a?(Hash)
        raise ValidationError, "#{source_path} section #{index} must be a mapping"
      end

      section = section.deep_stringify_keys
      validate_value!(section["title"].present?, "section #{index} title is required")

      content_keys = %w[paragraphs items table paragraphs_after]
      return if content_keys.any? { |key| section[key].present? }

      raise ValidationError, "#{source_path} section #{index} must contain body content"
    end

    def string_value(key)
      value = data.fetch(key)
      unless value.is_a?(String) && value.present?
        raise ValidationError, "#{source_path} #{key} must be a non-empty string"
      end

      value
    end

    def date_value(key)
      Date.iso8601(data.fetch(key).to_s)
    rescue Date::Error
      raise ValidationError, "#{source_path} #{key} must be an ISO 8601 date"
    end

    def boolean_value(key)
      value = data.fetch(key)
      return value if value == true || value == false

      raise ValidationError, "#{source_path} #{key} must be true or false"
    end

    def validate_value!(condition, message)
      return if condition

      raise ValidationError, "#{source_path} #{message}"
    end

    def normalize_for_digest(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [ key, normalize_for_digest(value[key]) ] }
      when Array
        value.map { |item| normalize_for_digest(item) }
      else
        value
      end
    end
  end
end
