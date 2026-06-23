# frozen_string_literal: true

class LegalConsentsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_legal_documents_status
  before_action :set_requirement, if: :legal_documents_ready?

  def show
    unless legal_documents_ready?
      render_unavailable
      return
    end

    redirect_to after_legal_consent_path, notice: t("legal_consents.flash.already_current"), status: :see_other unless @requirement.required?
  end

  def create
    unless legal_documents_ready?
      render_unavailable
      return
    end

    unless @requirement.required?
      redirect_to after_legal_consent_path, notice: t("legal_consents.flash.already_current"), status: :see_other
      return
    end

    unless legal_agreement_accepted?
      @legal_agreement_error = t("legal_consents.errors.agreement_required")
      render :show, status: :unprocessable_content
      return
    end

    LegalAcceptances::Recorder.record_current_documents!(
      user: current_user,
      acceptance_context: "reconsent",
      request: request,
      locale: legal_consent_locale
    )

    redirect_to after_legal_consent_path, notice: t("legal_consents.flash.accepted"), status: :see_other
  end

  private

  def set_legal_documents_status
    @legal_documents_status = current_legal_documents_status
  end

  def legal_documents_ready?
    @legal_documents_status.ready?
  end

  def render_unavailable
    @legal_documents_unavailable = true
    flash.now[:alert] = t("flash.legal_documents.unavailable")
    render :show, status: :service_unavailable
  end

  def set_requirement
    @requirement = LegalConsents::Requirement.new(user: current_user, locale: legal_consent_locale)
  end

  def legal_agreement_accepted?
    ActiveModel::Type::Boolean.new.cast(params[:legal_agreement])
  end

  def after_legal_consent_path
    safe_return_path(session.delete(ApplicationController::LEGAL_CONSENT_RETURN_TO_SESSION_KEY)) || receipts_path
  end

  def safe_return_path(path)
    path = path.to_s
    return if path.blank?
    return unless path.start_with?("/")
    return if path.start_with?("//")

    uri = URI.parse(path)
    return if uri.host.present? || uri.scheme.present?

    path
  rescue URI::InvalidURIError
    nil
  end
end
