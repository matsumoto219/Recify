# frozen_string_literal: true

class RobotsController < ApplicationController
  ROBOTS_POLICY = <<~TEXT
    User-agent: *
    Disallow: /admin
    Disallow: /receipts
    Disallow: /settings
    Disallow: /notifications
    Disallow: /users
    Disallow: /legal/consent
    Disallow: /up
    Disallow: /rails/active_storage/
    Allow: /
    Sitemap: /sitemap.xml
  TEXT

  def show
    render plain: ROBOTS_POLICY, content_type: "text/plain"
  end
end
