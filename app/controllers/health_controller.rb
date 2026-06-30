# frozen_string_literal: true

class HealthController < ActionController::Base
  layout false

  def show
    response.set_header("Cache-Control", "no-store")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    render :show, status: :ok, content_type: "text/html"
  end
end
