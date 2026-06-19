# frozen_string_literal: true

class AnnouncementsController < ApplicationController
  INDEX_LIMIT = 10

  def index
    @pagy, @announcements = pagy(
      :offset,
      Announcement.visible_on_public.ordered_for_public,
      limit: self.class.index_limit
    )
  end

  def show
    @announcement = Announcement.visible_on_public
                                .includes(:announcement_links)
                                .find_by!(public_id: params[:public_id])
    @announcement_links = @announcement.announcement_links.order(:position, :id).select(&:valid?)
  end

  def self.index_limit
    SystemSettings.limit_for("limits.public_announcements_per_page")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    INDEX_LIMIT
  end
end
