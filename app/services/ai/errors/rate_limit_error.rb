module Ai
  module Errors
    # RateLimitError は、AIプロバイダーのレート制限に達した場合に発生する例外です。
    #
    # 現在の役割:
    # - 種別判定用（例: HTTP 429 エラー）
    # - 上位レイヤー（Ai::Client）で retry / fallback の挙動を判断するために使用
    #
    # このクラスは意図的に追加ロジックを持たせていません。
    #
    # 以下のようなケースで必要になった場合のみ実装を追加予定:
    # - retry_after（再試行までの待機時間）の保持
    # - エラー発生回数や制限情報の記録
    # - プロバイダー固有のレート制御情報の吸収
    class RateLimitError < ProviderError
    end
  end
end
