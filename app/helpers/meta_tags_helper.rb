# frozen_string_literal: true

module MetaTagsHelper
  PUBLIC_META_ACTIONS = {
    "announcements" => %w[index show],
    "contact_requests" => %w[new create],
    "home" => %w[index],
    "legal" => %w[terms privacy]
  }.freeze
  DEFAULT_OG_IMAGE_PATH = "brand/recify-ogp.png"
  DEFAULT_TWITTER_CARD = "summary_large_image"

  def public_meta_page?
    PUBLIC_META_ACTIONS.fetch(controller_path, []).include?(action_name)
  end

  def page_meta_title
    title = content_for?(:meta_title) ? content_for(:meta_title) : content_for(:title)
    title = title.to_s.strip.presence || meta_site_name

    return title if title == meta_site_name
    return title if title.end_with?(" | #{meta_site_name}")

    t("meta.title_format", title: title, site: meta_site_name)
  end

  def page_meta_description
    description = content_for?(:meta_description) ? content_for(:meta_description) : nil
    description.to_s.squish.presence || t("meta.default_description")
  end

  def page_canonical_url
    explicit_url = content_for?(:canonical_url) ? content_for(:canonical_url) : nil
    explicit_url.to_s.presence || absolute_public_url(request.path)
  end

  def page_og_type
    (content_for?(:meta_type) ? content_for(:meta_type) : nil).to_s.presence || "website"
  end

  def page_og_image_url
    explicit_url = content_for?(:og_image_url) ? content_for(:og_image_url) : nil
    explicit_url.to_s.presence || absolute_public_url(asset_path(DEFAULT_OG_IMAGE_PATH))
  end

  def render_public_meta_tags
    return unless public_meta_page?

    title = page_meta_title
    description = page_meta_description
    canonical_url = page_canonical_url
    og_image_url = page_og_image_url

    safe_join(
      [
        tag.meta(name: "description", content: description),
        tag.link(rel: "canonical", href: canonical_url),
        tag.meta(property: "og:site_name", content: meta_site_name),
        tag.meta(property: "og:title", content: title),
        tag.meta(property: "og:description", content: description),
        tag.meta(property: "og:type", content: page_og_type),
        tag.meta(property: "og:url", content: canonical_url),
        tag.meta(property: "og:image", content: og_image_url),
        tag.meta(name: "twitter:card", content: DEFAULT_TWITTER_CARD),
        tag.meta(name: "twitter:title", content: title),
        tag.meta(name: "twitter:description", content: description),
        tag.meta(name: "twitter:image", content: og_image_url)
      ],
      "\n"
    )
  end

  def absolute_public_url(path_or_url)
    value = path_or_url.to_s.strip
    return value if value.match?(%r{\Ahttps?://}i)

    origin = configured_public_origin || request_base_origin
    return value if origin.blank?

    path = value.start_with?("/") ? value : "/#{value}"
    "#{origin}#{path}"
  end

  def meta_text_excerpt(text, length: 120)
    visible_text = text.to_s.gsub(%r{<\s*(script|style)\b[^>]*>.*?<\s*/\s*\1\s*>}im, " ")
    truncate(strip_tags(visible_text).squish, length: length)
  end

  private

  def meta_site_name
    t("meta.site_name")
  end

  def configured_public_origin
    options = configured_public_url_options
    host = options[:host].to_s.strip.presence
    return if host.blank?

    protocol = options[:protocol].to_s.delete_suffix("://").presence
    protocol ||= Rails.env.production? ? "https" : request.protocol.delete_suffix("://")
    port = options[:port].presence
    port_fragment = port.present? ? ":#{port}" : nil

    "#{protocol}://#{host}#{port_fragment}"
  end

  def configured_public_url_options
    routes_options = Rails.application.routes.default_url_options.to_h.symbolize_keys
    return routes_options if routes_options[:host].present?

    Rails.application.config.action_mailer.default_url_options.to_h.symbolize_keys
  end

  def request_base_origin
    return if Rails.env.production?

    request.base_url
  end
end
