# frozen_string_literal: true

class LegalController < ApplicationController
  before_action -> { set_legal_document(:terms) }, only: :terms
  before_action -> { set_legal_document(:privacy) }, only: :privacy

  def terms; end

  def privacy; end

  def terms_versions
    set_legal_document_versions(:terms)
    render :versions
  end

  def terms_version
    set_legal_document_version(:terms)
    render :version
  end

  def privacy_versions
    set_legal_document_versions(:privacy)
    render :versions
  end

  def privacy_version
    set_legal_document_version(:privacy)
    render :version
  end

  private

  def set_legal_document(document_type)
    @legal_document = LegalDocument.current!(document_type, locale: I18n.locale)
    @legal_file_document = LegalDocuments.synchronized_file_for!(legal_document: @legal_document)
  end

  def set_legal_document_versions(document_type)
    @document_type = document_type.to_s
    @current_legal_document = LegalDocument.current!(@document_type, locale: I18n.locale)
    @legal_documents = LegalDocument.published
                                    .where(document_type: @document_type, locale: I18n.locale.to_s)
                                    .order(
                                      current: :desc,
                                      last_updated_on: :desc,
                                      published_on: :desc,
                                      version: :desc
                                    )
  end

  def set_legal_document_version(document_type)
    @legal_document = LegalDocument.published.find_by!(
      document_type: document_type.to_s,
      version: legal_document_version_param,
      locale: I18n.locale.to_s
    )
    @current_legal_document = LegalDocument.current!(document_type, locale: I18n.locale)
    @legal_file_document = LegalDocuments.synchronized_file_for!(legal_document: @legal_document)
  end

  def legal_document_version_param
    version = params[:version].to_s
    raise ActiveRecord::RecordNotFound unless version.match?(LegalDocument::VERSION_FORMAT)

    version
  end
end
