class GuestSessionsController < ApplicationController
  def create
    user = User.guest!
    sign_in user
    redirect_to receipts_path, notice: "ゲストログインしました"
  end
end
