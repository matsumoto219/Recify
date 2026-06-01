module PaginationHelper
  NavigationPaginationItem = Struct.new(:kind, :page, :url, keyword_init: true) do
    def gap?
      kind == :gap
    end

    def current?
      kind == :current
    end
  end

  NavigationPaginationState = Struct.new(
    :items,
    :current_page,
    :last_page,
    :back_url,
    :forward_url,
    :back_label,
    :forward_label,
    keyword_init: true
  ) do
    def render?
      last_page > 1
    end

    def back_enabled?
      back_url.present?
    end

    def forward_enabled?
      forward_url.present?
    end
  end

  def navigation_pagination_state(pagy)
    page_key = pagy.options.fetch(:page_key, "page")
    current_page = pagy.page
    last_page = pagy.last

    NavigationPaginationState.new(
      items: navigation_pagination_items(current_page:, last_page:, page_key:),
      current_page: current_page,
      last_page: last_page,
      back_url: navigation_pagination_url(pagy.previous, page_key:),
      forward_url: navigation_pagination_url(pagy.next, page_key:),
      back_label: t("common.pagination.previous"),
      forward_label: t("common.pagination.next")
    )
  end

  private

  def navigation_pagination_items(current_page:, last_page:, page_key:)
    visible_pages = ([ 1, last_page, current_page - 1, current_page, current_page + 1 ].select do |page|
      page.between?(1, last_page)
    end).uniq.sort

    visible_pages.each_with_object([]) do |page, items|
      items << NavigationPaginationItem.new(kind: :gap) if items.any? && page > items.last.page.to_i + 1
      kind = page == current_page ? :current : :link
      items << NavigationPaginationItem.new(kind: kind, page: page, url: navigation_pagination_url(page, page_key:))
    end
  end

  def navigation_pagination_url(page, page_key:)
    return if page.blank?

    url_for(request.query_parameters.merge(page_key => page, only_path: true))
  end
end
