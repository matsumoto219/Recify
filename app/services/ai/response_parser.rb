# AI ResponseParser実装時のルール:
# - AIの生レスポンスは直接使わない
# - 必ず response_parser を通して内部形式へ変換する
# - 内部形式は ReceiptAnalysisService に依存するため変更しない
