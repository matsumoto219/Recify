module Ai
  module Errors
    # AuthError は、AIプロバイダー呼び出し時の認証関連の失敗を表す例外です。
    #
    # 現在の役割:
    # - 種別判定用（例: 401 / 403 エラー）
    # - 上位レイヤー（Ai::Client）で retry / fallback の挙動を判断するために使用
    #
    # このクラスは意図的に追加ロジックを持たせていません。
    #
    # 以下のようなケースで必要になった場合のみ実装を追加予定:
    # - HTTPステータスコードの保持（401 / 403 の区別など）
    # - エラーごとの retry / fallback 制御
    # - プロバイダー固有の認証メタ情報の保持
    class AuthError < ProviderError
    end
  end
end
