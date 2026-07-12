# frozen_string_literal: true

require_relative "legal_documents/error"
require_relative "legal_documents/validation_error"
require_relative "legal_documents/file_document"
require_relative "legal_documents/repository"
require_relative "legal_documents/verifier"
require_relative "legal_documents"

class ProductionLegalDocumentsValidator
  ValidationError = Class.new(StandardError)
  Result = Struct.new(:missing_items, keyword_init: true) do
    def success?
      missing_items.empty?
    end
  end

  class << self
    def call(...)
      new(...).call
    end

    def validate!(...)
      new(...).validate!
    end
  end

  def initialize(database: false, verifier: LegalDocuments)
    @database = database
    @verifier = verifier
  end

  def call
    verify!
    Result.new(missing_items: [])
  rescue LegalDocuments::Error => e
    Result.new(missing_items: error_items(e))
  end

  def validate!
    result = call
    return result if result.success?

    raise ValidationError, "Invalid production legal documents: #{result.missing_items.join(', ')}"
  end

  private

  attr_reader :database, :verifier

  def verify!
    if database
      verifier.verify_database!
    else
      verifier.verify_files!
    end
  end

  def error_items(error)
    lines = error.message.to_s.lines.map { |line| line.squish }.reject(&:blank?)
    lines = [ "verification failed" ] if lines.empty?

    lines.map { |line| "#{error_prefix}: #{sanitize_error_line(line)}" }
  end

  def error_prefix
    database ? "legal_documents.database" : "legal_documents.files"
  end

  def sanitize_error_line(line)
    line.to_s.gsub(Rails.root.to_s, "[APP_ROOT]").truncate(240)
  end
end
