class GuestSessionsController < ApplicationController
  def create
    user = User.guest!
    sign_in user
    redirect_to receipts_path, notice: "ゲストログインしました"
  rescue StandardError => e
    Rails.logger.error("[GuestSessionsController] guest_sign_in_failed: #{e.class} #{e.message}")
    redirect_to new_user_session_path, alert: "ゲストログインに失敗しました"
  end
end
