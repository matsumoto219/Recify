class SettingsController < ApplicationController
  def index
    # ExternalServiceStatus から現在の状態を取得
    @ocr_state = ExternalServiceStatus.state(:ocr).to_sym
    @ai_state = ExternalServiceStatus.state(:ai).to_sym
  end

  def account
  end

  def security
  end
end
