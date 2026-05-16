require 'rails_helper'

RSpec.describe Ai::ResponseParser do
  let(:provider) { :openai }
  let(:meta) { {} }

  describe '.parse' do
    context '正常系' do
      let(:payload) do
        {
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
    end

    context 'items 不正' do
      it 'items が Array でない場合は ProviderError(analysis_items_invalid) を送出する' do
        payload = {
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
      it 'needs_review が boolean でない場合は ProviderError(analysis_value_invalid) を送出する' do
        payload = {
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
