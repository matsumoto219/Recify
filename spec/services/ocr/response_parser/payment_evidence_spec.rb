require 'rails_helper'

RSpec.describe Ocr::ResponseParser do
  def parse_payment_lines(lines, fields: {}, profile: ReceiptAnalysisProfiles.default)
    response = {
      'analyzeResult' => {
        'content' => lines.join("\n"),
        'pages' => [ { 'lines' => lines.map { |line| { 'content' => line } } } ],
        'documents' => [ { 'docType' => 'receipt', 'fields' => fields } ]
      }
    }
    described_class.new(response: response, profile: profile).call
  end

  it '商品直下の適用と決済欄の電子ギフトを区別する' do
    result = parse_payment_lines([ '検証品 800円', 'eGift適用 0円', '合計 864円', 'eGift適用 600円', 'eGift適用 400円', '釣銭 0円' ])

    expect(result.dig(:candidates, :payment_method_text)).to eq(ReceiptAnalysisProfiles.default.voucher_label)
  end

  it '電子ギフト販売と広告と商品直下0円だけでは方法へ昇格しない' do
    result = parse_payment_lines([ 'eGift販売 1000円', '検証品 800円', 'eGift適用 0円', '合計 864円', 'eGiftが使えます', '釣銭 0円' ])

    expect(result.dig(:candidates, :payment_method_text)).to be_nil
  end

  it '方法のsourceと額のsourceを個別に保持する' do
    fields = {
      'Payments' => {
        'valueArray' => [
          {
            'valueObject' => {
              'Method' => { 'valueString' => 'eGift', 'content' => 'eGift' },
              'Amount' => { 'valueCurrency' => { 'amount' => 600 }, 'content' => '600' }
            }
          }
        ]
      }
    }
    result = parse_payment_lines([ '合計 864円', 'eGift利用', '600円' ], fields: fields)

    expect(result.dig(:candidates, :payments)).to contain_exactly(
      include(
        method: 'eGift',
        amount: 600,
        method_source_line_index: 1,
        method_source_span_start: 0,
        method_source_span_end: 5,
        source_line_index: 2,
        source_span_start: 0,
        source_span_end: 3
      )
    )
  end

  it '注入したprofile語彙だけを電子ギフトとして扱う' do
    profile = ReceiptAnalysisProfiles.default.dup
    allow(profile).to receive(:ocr_voucher_payment_pattern).and_return(/TokenCredit/i)
    allow(profile).to receive(:ocr_payment_method_pattern).and_return(/TokenCredit/i)
    old = parse_payment_lines([ '合計 864円', 'eGift利用 1000円' ], profile: profile)
    replacement = parse_payment_lines([ '合計 864円', 'TokenCredit利用 1000円' ], profile: profile)

    expect(old.dig(:candidates, :payment_method_text)).to be_nil
    expect(replacement.dig(:candidates, :payment_method_text)).to eq(profile.voucher_label)
  end

  it 'provider spanなしの重複印字を最初の行へ推測対応しない' do
    fields = {
      'Payments' => {
        'valueArray' => [
          {
            'valueObject' => {
              'Method' => { 'valueString' => 'eGift', 'content' => 'eGift' },
              'Amount' => { 'valueCurrency' => { 'amount' => 500 }, 'content' => '500' }
            }
          }
        ]
      }
    }
    result = parse_payment_lines([ '合計 864円', 'eGift適用 500円', 'eGift適用 500円', '釣銭 0円' ], fields: fields)

    expect(result.dig(:candidates, :payments).first).not_to include(:method_source_line_index, :source_line_index)
  end

  it '広告の支払文言を方法に昇格せず税込合計後の実決済を抽出する' do
    result = parse_payment_lines([ '電子マネーのお支払いで表示価格から', '合計(税込)', '864円', 'WAON支払 864円', '釣銭 0円' ])

    expect(result.dig(:candidates, :payment_method_text)).to eq('waon')
  end

  it '否定された利用や使用可能だけの電子ギフトをOCR方法へ昇格しない' do
    unpaid = parse_payment_lines([ '合計 864円', 'eGift not paid 1000円', '釣銭 0円' ])
    available = parse_payment_lines([ '合計 864円', 'eGift使用可能 1000円', '釣銭 0円' ])
    used = parse_payment_lines([ '合計 864円', 'eGift使用 1000円', '釣銭 0円' ])

    expect(unpaid.dig(:candidates, :payment_method_text)).to be_nil
    expect(available.dig(:candidates, :payment_method_text)).to be_nil
    expect(used.dig(:candidates, :payment_method_text)).to eq(ReceiptAnalysisProfiles.default.voucher_label)
  end
end
