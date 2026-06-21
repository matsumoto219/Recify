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
end
