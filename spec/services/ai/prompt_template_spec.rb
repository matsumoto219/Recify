require 'rails_helper'

RSpec.describe Ai::PromptTemplate do
  describe '.build' do
    let(:input) do
      {
        meta: {
          country_region: 'JPN'
        },
        tax: {
          tax_details: [
            { rate: 0.1, amount: 45, net_amount: 455, description: '10%対象' }
          ],
          tax_context_lines: [
            '10%対象 455 45'
          ]
        },
        items: [
          {
            index: 0,
            raw_text: '50円切手',
            matched_content_lines: [ '50円切手 50' ],
            matched_filtered_content_lines: [ '50円切手 50' ]
          }
        ]
      }
    end

    let(:built_prompt) { described_class.build(input) }
    let(:system_prompt) { built_prompt[:system] }
    let(:user_prompt) { built_prompt[:user] }

    it 'country_region を item tax_rate 判断材料として使うよう指示する' do
      expect(user_prompt).to include(
        'Use country_region in meta as a reference for local tax rules when determining item tax_rate.'
      )
    end

    it 'country_region が不明な場合に特定国の税制を仮定しないよう指示する' do
      expect(user_prompt).to include(
        'Do not assume tax rules for a specific country or region when country_region is missing or unclear.'
      )
    end

    it '非課税可能性をレシート文面・商品名・周辺文脈から判断するよう指示する' do
      expect(user_prompt).to include(
        'For items that may be non-taxable or zero-rated, determine tax_rate from receipt text, item name, raw_text, matched_content_lines, matched_filtered_content_lines, and nearby context.'
      )
    end

    it '確信が低い場合は confidence を低くし、tax_rate を安全に選べない場合は null と needs_review true にするよう指示する' do
      expect(user_prompt).to include(
        'When tax_rate confidence is low, lower tax_rate_confidence instead of guessing.'
      )
      expect(user_prompt).to include(
        'When an item tax_rate cannot be selected safely, return null for tax_rate and set needs_review = true.'
      )
    end

    it '不確実な税率を一般的な税率へ無理に寄せないよう指示する' do
      expect(user_prompt).to include(
        'Do not force uncertain item tax rates into common local rates such as 0.08 or 0.1.'
      )
    end

    it 'tax_rate_confidence と tax_rate_reason の返却ルールを指示する' do
      aggregate_failures do
        expect(user_prompt).to include('tax_rate_confidence MUST be a decimal between 0.0 and 1.0 when returned.')
        expect(user_prompt).to include('tax_rate_reason MUST be a short enum-like string when returned.')
        expect(user_prompt).to include('standard_rate, reduced_rate, zero_or_exempt_candidate, tax_rate_not_visible, country_rule_uncertain, receipt_context_uncertain')
        expect(user_prompt).to include('tax_rate_confidence and tax_rate_reason may be returned even when tax_rate is null.')
      end
    end

    it 'AI response parser / normalizer の item schema に tax_rate metadata を許可する' do
      aggregate_failures do
        expect(system_prompt).to include('- tax_rate')
        expect(system_prompt).to include('- tax_rate_confidence')
        expect(system_prompt).to include('- tax_rate_reason')
        expect(system_prompt).to include('- needs_review')
        expect(Analysis::ReceiptItemNormalizer::AI_ALLOWED_KEYS).to eq(%i[
          index
          position_index
          suggested_name
          category
          needs_review
          tax_rate
          tax_rate_confidence
          tax_rate_reason
        ])
      end
    end
  end
end
