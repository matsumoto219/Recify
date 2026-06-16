class HomeController < ApplicationController
  def index
    redirect_to receipts_path if user_signed_in?
  end
end
