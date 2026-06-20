# frozen_string_literal: true

class SitemapController < ApplicationController
  layout false

  def show
    @static_paths = [
      root_path,
      terms_path,
      privacy_path,
      contact_path,
      announcements_path
    ]
    @announcements = Announcement.visible_on_public.ordered_for_public

    respond_to do |format|
      format.xml
    end
  end
end
