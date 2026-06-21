module LegalDocumentsHelper
  def legal_document_last_updated_text(legal_document)
    t(
      "legal.common.last_updated",
      date: legal_document_date(legal_document.last_updated_on)
    )
  end

  def legal_document_date(date)
    date = date.to_date
    "#{date.year}年#{date.month}月#{date.day}日"
  end

  def legal_document_current_path(document_type)
    case document_type.to_s
    when "terms"
      terms_path
    when "privacy"
      privacy_path
    end
  end

  def legal_document_versions_path(document_type)
    case document_type.to_s
    when "terms"
      terms_versions_path
    when "privacy"
      privacy_versions_path
    end
  end

  def legal_document_version_path(legal_document)
    case legal_document.document_type
    when "terms"
      terms_version_path(legal_document.version)
    when "privacy"
      privacy_version_path(legal_document.version)
    end
  end

  def legal_document_current_link_text(document_type)
    t("legal.version_navigation.current_#{document_type}")
  end

  def legal_document_type_label(document_type)
    t("legal.document_types.#{document_type}")
  end
end
