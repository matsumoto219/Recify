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
      message = t("flash.settings.update_success")

      respond_to do |format|
        format.json do
          render json: {
            ok: true,
            message: message,
            push_notification_enabled: current_user.push_notification_enabled,
            product_name_ai_completion_enabled: current_user.product_name_ai_completion_enabled,
            receipt_item_delete_confirmation_enabled: current_user.receipt_item_delete_confirmation_enabled,
            theme_preference: current_user.theme_preference
          }
        end

        format.turbo_stream do
          flash.now[:notice] = message if current_user.push_notification_enabled?
          render turbo_stream: turbo_stream.update("flash", partial: "shared/flash")
        end
      end
    else
      message = t("flash.settings.update_failure")

      respond_to do |format|
        format.json do
          render json: {
            ok: false,
            message: message,
            errors: current_user.errors.full_messages
          }, status: :unprocessable_content
        end

        format.turbo_stream do
          flash.now[:alert] = message
          render turbo_stream: turbo_stream.update("flash", partial: "shared/flash")
        end
      end
    end
  end

  private

  def settings_params
    params.require(:user).permit(
      :push_notification_enabled,
      :product_name_ai_completion_enabled,
      :receipt_item_delete_confirmation_enabled,
      :theme_preference
    )
  end
end
