# Versioning Policy

Recifyは、本方針に基づき[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)を採用します。このファイルを、公開互換性契約とバージョン番号を決定するための正本とします。

## 適用開始と基準版

- 方針採用日: 2026-07-17
- 互換性基準版: `v1.2.0`
- 本方針は、採用後に作成するrelease tagへ適用します。
- `v1.2.0`以前も`X.Y.Z`形式を使用していますが、Semantic Versioningへの準拠を遡及的には保証しません。
- 方針採用後の最初の版も機械的には決めず、`v1.2.0`からの変更内容に従って決定します。

公開版のバージョン番号は`MAJOR.MINOR.PATCH`形式、Git tagは`vMAJOR.MINOR.PATCH`形式とします。pre-release識別子とbuild metadataを使用する場合も、Semantic Versioning 2.0.0の構文と優先順位規則に従います。

## 公開互換性契約

本方針におけるSemantic Versioningのpublic APIは、Recifyを利用、管理、運用、または連携する際に保証する次の公開互換性契約を意味します。

- 公開文書に記載された利用者・管理者向け機能と、その主要な結果
- ブックマークまたは外部参照を想定すると明記した安定URL
- 保存済みデータの意味と、対応版から通常の手順でアップグレードした際にデータを保持できること
- 公開文書に記載した必須設定、対応環境、標準のデプロイ・migration手順
- デプロイをまたいで残り得るActive Jobのclass名、引数のserialization、および実行互換性
- 公開済みの入出力形式、download・export形式、外部連携仕様
- 将来stableとして公開するmobile APIまたはpublic APIのendpoint、HTTP method、認証、request・response、およびerror contract
- 利用者間のデータ分離、管理者権限、機密情報の非公開など、公開文書に記載したセキュリティ保証

「公開文書」は、Git管理されたREADME、`VERSIONING.md`、`CHANGELOG.md`、release notes、または公開互換性契約として明示した仕様を指します。

公開済みsoftware artifactを変更せず、正確な利用案内、リンク、画像、または誤記だけを
更新するdocumentation-only commitは、新しいreleaseを構成しません。repository固有の
allowlistに差分全体が収まり、実装、設定、依存関係、version metadata、security契約、
または公開互換性契約の意味を変えない場合は、`VERSION`、tag、`CHANGELOG.md`、
release notesを更新しません。案内の追加に見えても、利用可能な機能、保証する結果、
必須設定、対応環境、認証・認可、privacyまたはsecurity保証を変更する場合は、この例外を
使用せず、通常のrelease判定を行います。

同一major内では、`v1.2.0`または本方針採用後に公開された同一majorの対応版から、文書化された通常の手順でアップグレードできなければなりません。downgradeや旧版へのrollbackは、release notesで明示した場合を除き、互換性契約には含めません。

## 公開互換性契約に含めないもの

次のものは、外部向けの安定契約として別途文書化されない限り、公開互換性契約には含めません。

- 内部Ruby class、module、method、service、facade、query、formの名称と構成
- architecture文書やspecでpublic APIと呼ぶ、アプリケーション内部caller向けの境界
- DBのtable、column、indexなどの物理構造とmigrationの実装方法
- OCR・AI provider adapterと外部provider固有の内部処理
- 文書化されていないcontroller parameter、内部endpoint、内部JSON形式
- DOM構造、CSS class、Stimulus・Turboの内部構成
- 画面の配置、色、文言など、機能の主要な結果を変えない表示詳細
- test、fixture、内部ログ形式、実装上の依存ライブラリ

除外対象の変更であっても、公開互換性契約へ影響する場合は、その影響に従ってバージョンを決定します。

## バージョンの決定

複数の区分に該当する場合は、公開互換性契約への影響が最も大きい区分を採用します。

### MAJOR

公開互換性契約に後方互換性のない変更がある場合に更新します。

- 文書化された機能、認証方法、安定URL、外部連携仕様を削除または非互換に変更する
- 保存済みデータを失う、意味を非互換に変更する、または同一major内の対応版から通常のmigrationで更新できなくする
- 必須設定を互換手段なしで削除・改名し、従来の文書化されたデプロイを動作不能にする
- デプロイ中またはqueue内に残る従来のActive Jobをdeserialize・実行できなくする
- stableなmobile APIまたはpublic APIへ後方互換性のない変更を行う
- セキュリティ対応であっても、正当な利用方法を含む公開互換性契約を破る

major版を更新するときは、minorとpatchを`0`へ戻します。

### MINOR

公開互換性契約を維持した後方互換な機能追加、または公開契約の非推奨化がある場合に更新します。

- 利用者・管理者・運用者向け機能を追加する
- stableなAPIへ後方互換なendpointや機能を追加する
- 安全なdefaultを持つ任意設定を追加する
- 公開互換性契約の一部を非推奨にする
- 公開契約を維持したまま、大規模な内部機能・構造改善を公開版として区切る

minor版にはpatch相当の修正を含めることができます。通常のデプロイ手順で適用でき、保存済みデータと従来機能を保持するDB migrationは、それだけでは破壊的変更としません。minor版を更新するときはpatchを`0`へ戻します。

### PATCH

新しい公開機能や非推奨化を含まず、後方互換な不具合修正またはセキュリティ修正だけの場合に更新します。

- 文書化された動作から外れていた不具合を修正する
- 正当な利用方法を失わせずに脆弱性を修正または防御を強化する
- 修正に伴い、公開契約を変えない内部実装や依存ライブラリを変更する
- 実装済みの公開契約を変えずに、誤っていた文書を訂正する

新しい公開機能または公開契約の非推奨化を含む場合は、patchではなくminor以上とします。

## 非推奨化と削除

- 公開互換性契約の非推奨化はminor版で行います。
- `CHANGELOG.md`と該当release notesへ、対象、影響、代替手段、削除可能となるmajor版を記載します。
- 非推奨の機能は、原則として現在のmajor版の間は動作を維持します。
- 公開互換性契約からの削除または非互換変更は、次のmajor版で行います。
- 緊急のセキュリティ、privacy、法的対応では事前猶予を短縮できますが、破壊的変更をminorまたはpatchとして扱う理由にはしません。

内部実装だけに属する除外対象には、SemVer上の非推奨期間を要求しません。ただし、デプロイをまたぐActive Jobなど、公開互換性契約に含まれるものはこの限りではありません。

## DB migrationとActive Job

- 同一major内のmigrationは、保存済みデータを保持し、文書化された標準手順で適用できるようにします。
- destructive migration、データの意味に対する非互換変更、DB再構築を必須とする変更はmajor変更として扱います。
- productionへ適用済みのmigrationは変更せず、新しいmigrationで前進させます。
- Active Jobをrenameまたは移動する場合、queueに残るjobを安全に処理できるalias、移行、または事前drain手順を用意します。
- 従来のjobを安全に処理できない変更はmajor変更として扱います。

必要なmigration、デプロイ順序、運用操作、rollback上の制約はrelease notesへ記載します。

## セキュリティ変更

脆弱性修正や防御強化は、公開互換性契約を維持する場合はpatchとして公開できます。文書化された認可、データ分離、機密情報保護を本来の状態へ戻す修正は、保証済み動作の回復として扱います。

セキュリティ上の緊急性はバージョン区分を変更しません。破壊的変更が必要な場合はmajor版を更新します。公開文書には影響と対応を安全に要約し、悪用手順、未修正の詳細、secret、個人情報を記載しません。

## 将来のmobile API・public API

mobile APIまたはpublic APIを導入するときは、公開前にstableまたはexperimentalの状態を明記します。

- stable APIは公開互換性契約に含めます。
- experimental APIは安定契約の対象外であることを利用前に明記し、変更・削除の可能性を文書化します。
- stable APIの非互換変更はmajor版で行います。
- API固有のversioningを導入する場合も、アプリケーション全体のSemantic Versioningとの関係を文書化します。

## リリースの不変性

公開済みversionの内容は変更しません。

- 既存tagを移動、削除、上書き、または再作成しません。
- 同じversion番号で異なる内容を再公開しません。
- 公開後に問題が見つかった場合は、変更内容に応じた新しいversionを公開します。
- `VERSION`、Git tag、`CHANGELOG.md`、release notesのversionを一致させます。
- release後のdocumentation-only commitは、既存tagが指す公開済みsoftware artifactを
  変更しません。productionで稼働するversionはannotated release tagのtargetとdeploy
  記録で特定し、文書のみのcommitを既存releaseとしてtagし直しません。

## リリース判定

release準備時は、直近の公開版からrelease candidateまでを確認し、公開互換性契約への最大の影響でversionを決定します。判断できない変更は、公開契約を先に明確化します。互換性を客観的に確認できない場合は、より小さいversionへ推測で分類しません。

Semantic Versioningは、旧版の保守期間、全リリース間の直接アップグレード、zero-downtime deploy、downgrade、rollbackを自動的には保証しません。これらを保証する場合は、該当release notesまたは運用文書へ明記します。
