require 'rails_helper'

RSpec.describe Ai::ResponseParser do
  let(:provider) { :openai }
  let(:meta) { {} }

  describe '.parse' do
    context '正常系' do
      let(:payload) do
        {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {
            'store_name' => 'AI補正ストア',
            'store_address' => '東京都渋谷区1-2-3',
            'store_phone_number' => '03-1234-5678'
          },
          'purchase' => {
            'purchased_at_text' => '2026-04-15 12:34'
          },
          'payment' => {
            'payment_method' => 'credit_card'
          },
          'items' => [
            {
              'index' => 0,
              'suggested_name' => 'ブレンドコーヒー',
              'category' => 'drink',
              'needs_review' => false,
              'tax_rate' => 0.1,
              'tax_rate_confidence' => 0.62,
              'tax_rate_reason' => 'receipt_context_uncertain'
            },
            {
              'index' => 1,
              'suggested_name' => 'たまごサンド',
              'category' => 'food',
              'needs_review' => true
            }
          ],
          'needs_review' => true,
          'review_reasons' => [ 'item_name_uncertain' ]
        }
      end

      it '共通形式の success result を返す' do
        result = described_class.parse(payload, provider: provider, meta: meta)

        aggregate_failures do
          expect(result[:success]).to eq(true)
          expect(result[:error_code]).to be_nil
          expect(result[:needs_review]).to eq(true)
          expect(result[:review_reasons]).to eq([ 'item_name_uncertain' ])
          expect(result[:receipt_attributes]).to eq(
            'store_name' => 'AI補正ストア',
            'store_address' => '東京都渋谷区1-2-3',
            'store_phone_number' => '03-1234-5678',
            'purchased_at_text' => '2026-04-15 12:34',
            'payment_method' => 'credit_card'
          )
          expect(result[:receipt_items_attributes]).to eq([
            {
              index: 0,
              suggested_name: 'ブレンドコーヒー',
              category: 'drink',
              needs_review: false,
              tax_rate: BigDecimal('0.1'),
              tax_rate_confidence: BigDecimal('0.62'),
              tax_rate_reason: 'receipt_context_uncertain'
            },
            {
              index: 1,
              suggested_name: 'たまごサンド',
              category: 'food',
              needs_review: true
            }
          ])
          expect(result[:meta]).to eq(provider: :openai)
        end
      end

      it 'is_receipt true のconfidenceをmetaに保持する' do
        payload['is_receipt_confidence'] = 0.55

        result = described_class.parse(payload, provider: provider, meta: meta)

        aggregate_failures do
          expect(result[:success]).to eq(true)
          expect(result[:meta]).to eq(provider: :openai, is_receipt_confidence: 0.55)
        end
      end

      it 'is_receipt_confidence missing は nil として許容する' do
        result = described_class.parse(payload, provider: provider, meta: meta)

        expect(result[:meta]).not_to have_key(:is_receipt_confidence)
      end

      it 'is_receipt false の場合は ai_not_receipt error result を返す' do
        payload.merge!(
          'is_receipt' => false,
          'is_receipt_confidence' => 0.92,
          'document_type' => 'development_note',
          'rejection_reason' => 'memo',
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        )

        result = described_class.parse(payload, provider: provider, meta: meta)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_not_receipt')
          expect(result[:needs_review]).to eq(false)
          expect(result[:receipt_attributes]).to eq({})
          expect(result[:receipt_items_attributes]).to eq([])
          expect(result[:meta]).to eq(
            provider: :openai,
            is_receipt_confidence: 0.92,
            document_type: 'development_note',
            rejection_reason: 'memo'
          )
        end
      end

      it 'is_receipt_confidence が1を超える場合は1.0に丸める' do
        payload['is_receipt_confidence'] = 1.2

        result = described_class.parse(payload, provider: provider, meta: meta)

        expect(result[:meta]).to include(is_receipt_confidence: 1.0)
      end

      it 'is_receipt_confidence が0未満の場合は0.0に丸める' do
        payload['is_receipt_confidence'] = -0.2

        result = described_class.parse(payload, provider: provider, meta: meta)

        expect(result[:meta]).to include(is_receipt_confidence: 0.0)
      end

      it 'is_receipt_confidence が非数値の場合は nil として許容する' do
        payload['is_receipt_confidence'] = 'high'

        result = described_class.parse(payload, provider: provider, meta: meta)

        expect(result[:meta]).not_to have_key(:is_receipt_confidence)
      end

      it 'is_receipt false で screenshot reason を保持する' do
        payload.merge!(
          'is_receipt' => false,
          'document_type' => 'screenshot',
          'rejection_reason' => 'screenshot',
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        )

        result = described_class.parse(payload, provider: provider, meta: meta)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_not_receipt')
          expect(result[:meta]).to include(rejection_reason: 'screenshot')
        end
      end

      it 'not receipt の代表的なrejection_reason分類を保持する' do
        %w[screenshot menu shopping_list memo article poster unknown_document].each do |reason|
          payload.merge!(
            'is_receipt' => false,
            'is_receipt_confidence' => 0.91,
            'document_type' => reason,
            'rejection_reason' => reason,
            'store' => {},
            'purchase' => {},
            'payment' => {},
            'items' => [],
            'needs_review' => false,
            'review_reasons' => []
          )

          result = described_class.parse(payload, provider: provider, meta: meta)

          aggregate_failures(reason) do
            expect(result[:success]).to eq(false)
            expect(result[:error_code]).to eq('ai_not_receipt')
            expect(result[:meta]).to include(
              rejection_reason: reason,
              is_receipt_confidence: 0.91
            )
          end
        end
      end

      it 'is_receipt false で未知reasonは unknown_document に丸める' do
        payload.merge!(
          'is_receipt' => false,
          'document_type' => 'unknown',
          'rejection_reason' => 'not_receipt',
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        )

        result = described_class.parse(payload, provider: provider, meta: meta)

        expect(result[:meta]).to include(rejection_reason: 'unknown_document')
      end

      it 'is_receipt false でblank reasonは unknown_document に丸める' do
        payload.merge!(
          'is_receipt' => false,
          'document_type' => 'unknown',
          'rejection_reason' => ' ',
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        )

        result = described_class.parse(payload, provider: provider, meta: meta)

        expect(result[:meta]).to include(rejection_reason: 'unknown_document')
      end

      it 'is_receipt true では rejection_reason があってもsuccess側に影響しない' do
        payload['rejection_reason'] = 'memo'

        result = described_class.parse(payload, provider: provider, meta: meta)

        aggregate_failures do
          expect(result[:success]).to eq(true)
          expect(result[:error_code]).to be_nil
          expect(result[:meta]).to eq(provider: :openai)
        end
      end

      it 'promptで許可しているreview_reasonsを保持する' do
        payload['review_reasons'] = [
          'item_tax_rate_uncertain',
          'ocr_unreadable',
          'ocr_low_confidence'
        ]

        result = described_class.parse(payload, provider: provider, meta: meta)

        expect(result[:review_reasons]).to eq([
          'item_tax_rate_uncertain',
          'ocr_unreadable',
          'ocr_low_confidence'
        ])
      end
    end

    describe 'review reason definitions' do
      def prompt_allowed_review_reasons
        Ai::PromptTemplate.new({}).send(:allowed_review_reasons)
      end

      def locale_review_reason_keys
        I18n.t('enums.receipt_item.review_reason').keys.map(&:to_s)
      end

      it 'keeps parser and prompt allowed review reasons in sync' do
        expect(described_class::ALLOWED_REVIEW_REASONS).to match_array(prompt_allowed_review_reasons)
      end

      it 'has locale translations for parser allowed review reasons' do
        expect(locale_review_reason_keys).to include(*described_class::ALLOWED_REVIEW_REASONS)
      end

      it 'has locale translations for prompt allowed review reasons' do
        expect(locale_review_reason_keys).to include(*prompt_allowed_review_reasons)
      end

      it 'has locale translations for amount mismatch reasons' do
        expect(locale_review_reason_keys).to include(*Amounts::MismatchCodes.all.map(&:to_s))
      end
    end

    context '必須キー不足' do
      it 'store が無い場合は ProviderError(analysis_missing_keys) を送出する' do
        payload = {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        }

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('analysis_missing_keys')
            expect(error.provider).to eq(provider)
          end
        }
      end

      it 'items が無い場合は ProviderError(analysis_missing_keys) を送出する' do
        payload = {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'needs_review' => false,
          'review_reasons' => []
        }

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('analysis_missing_keys')
            expect(error.provider).to eq(provider)
          end
        }
      end

      it 'is_receipt が無い場合は ProviderError(analysis_missing_keys) を送出する' do
        payload = {
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        }

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('analysis_missing_keys')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end

    context 'items 不正' do
      it 'items が Array でない場合は ProviderError(analysis_items_invalid) を送出する' do
        payload = {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => 'invalid',
          'needs_review' => false,
          'review_reasons' => []
        }

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('analysis_items_invalid')
            expect(error.provider).to eq(provider)
          end
        }
      end

      it 'item が Hash でない場合は ProviderError(analysis_items_invalid) を送出する' do
        payload = {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [ 'invalid' ],
          'needs_review' => false,
          'review_reasons' => []
        }

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('analysis_items_invalid')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end

    context '値不正' do
      it 'is_receipt が boolean でない場合は ProviderError(analysis_value_invalid) を送出する' do
        payload = {
          'is_receipt' => 'yes',
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        }

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('analysis_value_invalid')
            expect(error.provider).to eq(provider)
          end
        }
      end

      it 'needs_review が boolean でない場合は ProviderError(analysis_value_invalid) を送出する' do
        payload = {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => 'yes',
          'review_reasons' => []
        }

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('analysis_value_invalid')
            expect(error.provider).to eq(provider)
          end
        }
      end

      it 'review_reasons が Array でない場合は ProviderError(analysis_value_invalid) を送出する' do
        payload = {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => 'invalid'
        }

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('analysis_value_invalid')
            expect(error.provider).to eq(provider)
          end
        }
      end

      it 'store が Hash でない場合は ProviderError(analysis_value_invalid) を送出する' do
        payload = {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => 'invalid',
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        }

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.error_code).to eq('analysis_value_invalid')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end

    context '非Hash入力' do
      let(:payload) { 'invalid response' }

      it 'ProviderError(ai_invalid_response) を送出する' do
        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.message).to eq('AI payload must be a Hash')
            expect(error.error_code).to eq('ai_invalid_response')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end

    context 'ProviderError' do
      let(:payload) do
        {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        }
      end

      it 'ProviderError はそのまま送出する' do
        allow(Analysis::ReceiptItemNormalizer).to receive(:normalize_ai_items)
          .and_raise(Ai::Errors::ProviderError.new(message: 'provider invalid', error_code: 'ai_invalid_response', provider: provider))

        expect do
          described_class.parse(payload, provider: provider, meta: meta)
        end.to raise_error(Ai::Errors::ProviderError) { |error|
          aggregate_failures do
            expect(error.message).to eq('provider invalid')
            expect(error.error_code).to eq('ai_invalid_response')
            expect(error.provider).to eq(provider)
          end
        }
      end
    end

    context '予期しない例外' do
      let(:payload) do
        {
          'is_receipt' => true,
          'document_type' => 'receipt',
          'rejection_reason' => nil,
          'store' => {},
          'purchase' => {},
          'payment' => {},
          'items' => [],
          'needs_review' => false,
          'review_reasons' => []
        }
      end

      it '内部エラー時は ai_invalid_response の error result を返す' do
        allow(Analysis::ReceiptItemNormalizer).to receive(:normalize_ai_items).and_raise(StandardError.new('boom'))

        result = described_class.parse(payload, provider: provider, meta: meta)

        aggregate_failures do
          expect(result[:success]).to eq(false)
          expect(result[:error_code]).to eq('ai_invalid_response')
          expect(result[:needs_review]).to eq(true)
          expect(result[:receipt_attributes]).to eq({})
          expect(result[:receipt_items_attributes]).to eq([])
          expect(result[:meta]).to eq(
            provider: :openai,
            error_class: 'StandardError',
            error_message: 'boom'
          )
        end
      end
    end
  end
end
