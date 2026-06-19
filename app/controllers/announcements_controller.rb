# frozen_string_literal: true

class AnnouncementsController < ApplicationController
  INDEX_LIMIT = 10

  def index
    @pagy, @announcements = pagy(
      :offset,
      Announcement.visible_on_public.ordered_for_public,
      limit: INDEX_LIMIT
    )
  end

  def show
    @announcement = Announcement.visible_on_public
                                .includes(:announcement_links)
                                .find_by!(public_id: params[:public_id])
    @announcement_links = @announcement.announcement_links.order(:position, :id).select(&:valid?)
  end
end
