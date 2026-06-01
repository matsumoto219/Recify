module ContactRequestsHelper
  def contact_request_category_options(values = ContactRequests.category_options)
    Array(values).map { |category| [ t("contact_requests.categories.#{category}"), category ] }
  end
end
