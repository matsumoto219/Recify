<p align="center">
  <img src=".github/readme/recify-logo-full.png" alt="Recify" width="320">
</p>

# Recify

Recifyは、レシート画像をアップロードし、OCR解析とAI補完によって店舗名・日付・金額・明細・カテゴリ整理を支援するレシート管理アプリです。

支出記録を、画像アップロード、解析、確認、編集、保存までの流れで扱えるようにすることを目指しています。

## URL

- URL: https://recify-app.com

## 開発背景

レシートは紙のままだと保管・検索・集計がしづらく、手入力にも負担がかかります。Recifyは、レシート画像や手動入力から支出データを半自動で記録し、日々の入力・整理の手間を減らすことを目的に開発しました。

## 設計上のポイント

- OCR/AIは確定値ではなく入力補助として扱い、OCR原文、AI候補、ユーザー確定値を分けて保持します。
- 税率、割引、支払調整、丸めを考慮し、OCR/AIの候補値を保存前に金額整合性チェックへ通します。
- 画像解析はバックグラウンドで処理し、解析完了までブラウザ上で待機しなくてもよい設計にしています。
- AIが利用できない場合でも、OCR結果をもとに最低限の確認・編集を進められるようにしています。
- ゲスト利用から本登録へ移行できる導線を用意し、メール確認や規約同意を組み合わせています。

## 主な機能

- レシート画像アップロード
- OCR解析による店舗名、日付、合計金額、明細候補の抽出
- AI補完によるカテゴリ分類や商品名整理の支援
- 明細、税区分、支払情報、合計金額の確認・編集
- 税率、割引、支払調整を含む金額整合性チェック
- レシート一覧、検索、詳細表示
- ゲスト利用と通常ユーザーへの本登録
- メール確認、パスワード再設定、アカウントロック解除
- パスキー、認証アプリ、リカバリーコードを使った認証強化
- ライト/ダークテーマ切替
- お知らせ、通知、問い合わせ
- 利用規約・プライバシーポリシーの同意管理

## 利用フロー

1. レシート画像をアップロードします。
2. OCRで店舗名、日付、金額、明細候補を抽出します。
3. 必要に応じてAI補完でカテゴリや商品名整理を支援します。
4. ユーザーが明細、税率、支払情報、調整額を確認・編集します。
5. 金額整合性を確認し、レシートとして保存します。

## 使用技術

**アプリケーション**

| 使用技術 | 詳細 |
| --- | --- |
| Ruby 4.0.5 | アプリケーション実行環境 |
| Ruby on Rails 8.1.3 | Webアプリケーションフレームワーク |
| PostgreSQL | レシート、ユーザー、管理・監査データの保存 |
| Turbo / Stimulus | 画面遷移、フォーム操作、UI制御 |
| Tailwind CSS | UIスタイリング |
| Devise | ユーザー認証、メール確認、パスワード再設定 |
| WebAuthn | パスキー登録・ログイン |
| Active Storage | レシート画像の添付管理 |
| Solid Queue / Solid Cache / Solid Cable | 非同期ジョブ、キャッシュ、リアルタイム更新 |

<br>

**OCR / AI / 外部サービス**

| 使用技術 | 詳細 |
| --- | --- |
| Azure Document Intelligence | レシート画像から店舗名、日付、金額、明細候補を抽出 |
| OpenAI API | カテゴリ分類や商品名整理などのAI補完 |
| Resend | 認証メールや問い合わせ関連メールの送信 |
| Sentry | エラー監視 |
| Cloudflare Turnstile | bot対策 |

<br>

**インフラ / 運用**

| 使用技術 | 詳細 |
| --- | --- |
| AWS Lightsail | アプリケーション実行基盤 |
| Docker | アプリケーション実行環境のコンテナ化 |
| Kamal | コンテナデプロイ |
| Cloudflare | DNS/CDN、入口保護、Abuse protection |
| Lightsail snapshots / metrics alarms | バックアップとメトリクス通知 |

<br>

**品質確認**

| 使用技術 | 詳細 |
| --- | --- |
| RSpec | モデル、リクエスト、サービス、ジョブなどのテスト |
| RuboCop | Rubyコードの静的解析 |
| ERB Lint | ERBテンプレートのLint |
| StandardJS | JavaScriptのLint |
| Stylelint | CSSのLint |
| gitleaks | secret混入検知 |
| bundler-audit / brakeman | 依存GemとRailsアプリのセキュリティチェック |

## OCR / AI補完

Recifyの解析フローは、OCR、AI補完、保存判定を分けて扱います。

- OCRはAzure Document Intelligenceを利用し、レシート画像から候補値を抽出します。
- AI補完はOpenAI APIを利用し、カテゴリや商品名整理を支援します。
- OCR結果とAI結果をそのまま保存せず、金額整合性やレビュー判定を組み合わせます。
- AIが不確かな内容は、ユーザー確認が必要な状態として扱います。
- 外部サービス障害時は、認証エラー、利用制限、タイムアウト、解析失敗を分けて扱います。
- OCR/AI機能は実装済みで、運用設定により利用範囲や公開状態を制御できる設計です。
- 抽出結果は常に正しいものとして扱わず、必要に応じてユーザーが確認・修正する前提です。

## 金額計算 / 税率対応

OCRやAIの候補値を元に、アプリ側で金額の整合性を確認する方針にしています。

- 税込・税抜の金額を扱えるように整数円で正規化
- 8% / 10% など複数税率に対応
- 明細単位、税率単位、支払単位の情報を分けて保持
- 割引、ポイント利用、キャッシュレス還元などの支払調整に対応
- 丸め設定を考慮した合計金額の検算
- OCR/AI結果に矛盾がある場合は、保存前に確認が必要な状態として扱う

## セキュリティ・運用面の工夫

公開運用を想定し、認証、管理画面、ログ、監視、バックアップの基本を整えています。

- Deviseベースの認証
- メール確認、ロック、ログイン履歴管理
- Passkey / WebAuthn対応
- 認証アプリとリカバリーコードによる追加認証
- ゲスト利用から本登録への安全な導線
- 管理者向けの重要操作に対する追加確認
- Cloudflareを利用した公開前提の入口保護
- Turnstileによるbot対策
- Rails / Sentry / structured logでの認証情報の秘匿
- 外部API連携時の安全なメタデータ記録
- Sentryによるエラー監視
- DBと添付画像を対象にしたバックアップ・復旧確認
- Lightsail snapshotとメトリクス通知
- 法務文書の同期と同意履歴管理
- HSTSは公開後の安定状況を見て段階導入予定

## 管理画面

管理画面は通常ユーザー向け導線とは分離し、管理権限と保護されたアクセス経路を前提にしています。重要な管理操作では、操作理由や追加確認を組み合わせて安全性を高めています。

## 画面構成

- LP
- 認証画面
- レシート一覧
- レシート登録
- レシート詳細 / 編集
- 設定
- 通知
- 問い合わせ
- 法務ページ
- 管理者画面

## ER図

主要モデルだけを抜粋した簡易ER図です。読みやすいように、ドメインごとにグループ分けしています。

```mermaid
flowchart TB
  users["users<br/>account / admin / guest"]

  subgraph auth["Account / Auth"]
    direction TB
    auth_records["passkeys<br/>user_sessions<br/>TOTP / recovery codes<br/>usage limits"]
  end

  subgraph receipt["Receipt domain"]
    direction TB
    receipts["receipts<br/>status / store / total"]
    receipt_details["receipt_items<br/>receipt_tax_details<br/>receipt_payments<br/>receipt_adjustments"]
    attachments["Active Storage<br/>receipt image"]
  end

  subgraph analysis["OCR / AI analysis"]
    direction TB
    runs["receipt_analysis_runs<br/>provider / phase / status"]
  end

  subgraph legal["Legal documents"]
    direction TB
    legal_documents["legal_documents"]
  end

  subgraph content["Public content"]
    direction TB
    public_content["announcements<br/>announcement_links"]
  end

  subgraph support["User support records"]
    direction TB
    support_records["legal_acceptances<br/>contact_requests<br/>notifications"]
  end

  subgraph ops["Admin / Audit"]
    direction TB
    ops_records["audit_logs<br/>security events<br/>system_settings"]
  end

  users --> auth_records
  users --> receipts
  users --> support_records
  users -.-> public_content
  users -.-> ops_records
  receipts --> receipt_details
  receipts --> runs
  receipts --> attachments
  receipts -.-> ops_records
  legal_documents --> support_records
  ops_records -.-> runs

  classDef account fill:#eef2ff,stroke:#6366f1,color:#111827;
  classDef receipt fill:#ecfdf5,stroke:#10b981,color:#111827;
  classDef analysis fill:#fff7ed,stroke:#f97316,color:#111827;
  classDef support fill:#fdf2f8,stroke:#ec4899,color:#111827;
  classDef ops fill:#f8fafc,stroke:#64748b,color:#111827;

  class users,auth_records account;
  class receipts,receipt_details,attachments receipt;
  class runs analysis;
  class legal_documents,public_content,support_records support;
  class ops_records ops;
```

## インフラ構成

以下は、Recifyの本番運用で利用している主要サービスのインフラ構成図です。

![Recify infrastructure diagram](.github/readme/infrastructure.png)

## 今後の改善予定

- 統計ページの追加
  - グラフ表示
  - 月別・年別集計
  - カテゴリ別や購入内容ごとの割合表示
- S3 / R2など外部オブジェクトストレージへの移行
- OCR / AI精度改善
- レシート分類・検索体験の強化
- スマホアプリ向けAPIの実装
