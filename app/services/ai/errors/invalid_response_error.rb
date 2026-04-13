module Ai
  module Errors
    # InvalidResponseError は、AIプロバイダーから返却されたレスポンスが不正な場合に発生する例外です。
    #
    # 現在の役割:
    # - 種別判定用（例: JSONパース失敗、必須キー欠損など）
    # - 上位レイヤー（Ai::Client）で retry / fallback の挙動を判断するために使用
    #
    # このクラスは意図的に追加ロジックを持たせていません。
    #
    # 以下のようなケースで必要になった場合のみ実装を追加予定:
    # - 生レスポンス（body）やパース結果の保持
    # - エラー箇所の詳細情報の付与
    # - プロバイダー固有のレスポンス差異の吸収
    class InvalidResponseError < ProviderError
    end
  end
end
