class HomeController < ApplicationController
  def index
    return redirect_to receipts_path if user_signed_in?

    @announcements = Announcement.visible_on_public.ordered_for_public.limit(6)
  end
end
