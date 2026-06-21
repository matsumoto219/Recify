# frozen_string_literal: true

class LegalController < ApplicationController
  before_action -> { set_legal_document(:terms) }, only: :terms
  before_action -> { set_legal_document(:privacy) }, only: :privacy

  def terms; end

  def privacy; end

  private

  def set_legal_document(document_type)
    @legal_document = LegalDocument.current!(document_type, locale: I18n.locale)
    @legal_file_document = legal_document_repository.find!(
      document_type: @legal_document.document_type,
      version: @legal_document.version,
      locale: @legal_document.locale
    )

    validate_legal_document_file!
  end

  def legal_document_repository
    @legal_document_repository ||= LegalDocuments::Repository.new
  end

  def validate_legal_document_file!
    return if @legal_file_document.source_path == @legal_document.source_path &&
              @legal_file_document.content_digest == @legal_document.content_digest

    raise LegalDocuments::ValidationError, "Legal document #{@legal_document.source_path} is not synchronized"
  end
end
