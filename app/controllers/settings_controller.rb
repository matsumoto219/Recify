class SettingsController < ApplicationController
  before_action :authenticate_user!

  def index
    prepare_index
  end

  def account
  end

  def security
    @security_presenter = Settings::SecurityPresenter.new(user: current_user)
  end

  def update
    if current_user.update(settings_params)
      message = t("flash.settings.update_success")

      respond_to do |format|
        format.html do
          redirect_to settings_path, notice: message, status: :see_other
        end

        format.json do
          render json: {
            ok: true,
            message: message,
            push_notification_enabled: current_user.push_notification_enabled,
            product_name_ai_completion_enabled: current_user.product_name_ai_completion_enabled,
            delete_confirmation_enabled: current_user.delete_confirmation_enabled,
            keep_receipt_images: current_user.keep_receipt_images,
            theme_preference: current_user.theme_preference,
            tax_rounding_mode: current_user.tax_rounding_mode,
            discount_rounding_mode: current_user.discount_rounding_mode
          }
        end

        format.turbo_stream do
          flash.now[:notice] = message if current_user.push_notification_enabled?
          render turbo_stream: settings_update_streams
        end
      end
    else
      message = t("flash.settings.update_failure")

      respond_to do |format|
        format.html do
          current_user.reload
          prepare_index
          flash.now[:alert] = message
          render :index, status: :unprocessable_content
        end

        format.json do
          render json: {
            ok: false,
            message: message,
            errors: current_user.errors.full_messages
          }, status: :unprocessable_content
        end

        format.turbo_stream do
          flash.now[:alert] = message
          render turbo_stream: turbo_stream.append("toast-stream", partial: "shared/ui/feedback/flash"),
                 status: :unprocessable_content
        end
      end
    end
  end

  private

  def prepare_index
    @ocr_state = ExternalServices.state(:ocr).to_sym
    @ai_state = ExternalServices.state(:ai).to_sym
    @settings_index_presenter = Settings::IndexPresenter.new(user: current_user, view_context: view_context)
  end

  def settings_params
    params.require(:user).permit(
      :push_notification_enabled,
      :product_name_ai_completion_enabled,
      :delete_confirmation_enabled,
      :keep_receipt_images,
      :theme_preference,
      :tax_rounding_mode,
      :discount_rounding_mode
    )
  end

  def settings_update_streams
    [
      turbo_stream.append("toast-stream", partial: "shared/ui/feedback/flash"),
      turbo_stream.replace(
        "notifications_dropdown_content",
        partial: "shared/notifications/dropdown_content",
        locals: {
          notifications: notifications_dropdown_items
        }
      )
    ]
  end
end
