class SettingsController < ApplicationController
  before_action :authenticate_user!

  def index
    # ExternalServiceStatus から現在の状態を取得
    @ocr_state = ExternalServiceStatus.state(:ocr).to_sym
    @ai_state = ExternalServiceStatus.state(:ai).to_sym
  end

  def account
  end

  def security
  end

  def update
    if current_user.update(settings_params)
      render json: {
        ok: true,
        push_notification_enabled: current_user.push_notification_enabled
      }
    else
      render json: {
        ok: false,
        errors: current_user.errors.full_messages
      }, status: :unprocessable_entity
    end
  end

  private

  def settings_params
    params.require(:user).permit(:push_notification_enabled)
  end
end
