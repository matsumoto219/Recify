require 'rails_helper'

RSpec.describe Analysis::ReceiptPaymentEvidenceExtractor do
  let(:profile) { ReceiptAnalysisProfiles.default }

  def evidence(lines, payments: [], items: [], profile: self.profile)
    described_class.call(candidates: { payments: payments, items: items }, lines: lines, profile: profile)
  end

  it 'カードの金額ラベルが文末でも方法を保持し欠損額を補完しない' do
    result = evidence([ '合計 864円', 'クレジット支払', '金額' ])

    expect(result[:payments]).to contain_exactly(include(method: 'クレジット支払', amount: nil, amount_role: 'unknown'))
    expect(result[:settlement]).to include(complete: false, observed_ambiguity: true)
  end

  it '電子ギフトの支払額ラベルが文末でも額を借用しない' do
    result = evidence([ '合計 864円', 'eGift適用', '支払額' ])

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: nil, amount_role: 'unknown'))
    expect(result[:settlement]).to include(complete: false, observed_ambiguity: true)
  end

  it '金額ラベルの後でも終了した決済欄を越えて別の金額を関連付けない' do
    result = evidence([ '合計 864円', 'クレジット支払', '金額', 'ありがとうございました', '864円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'クレジット支払', amount: nil, amount_role: 'unknown'))
    expect(result[:settlement][:source_end_line_index]).to eq(3)
  end

  it '釣銭が預りを超える場合は預りを実充当額として残さない' do
    result = evidence([ '合計 864円', '現金 1000円', 'お釣り 2000円' ])

    expect(result[:payments]).to contain_exactly(include(method: '現金', amount: nil, printed_amount: 1000, amount_role: 'unknown'))
    expect(result[:settlement]).to include(complete: false, observed_ambiguity: true)
  end

  it '釣銭ラベルの額が欠けた場合は預りを実充当額として残さない' do
    result = evidence([ '合計 864円', '現金 1000円', 'お釣り' ])

    expect(result[:payments]).to contain_exactly(include(method: '現金', amount: nil, printed_amount: 1000, amount_role: 'unknown'))
    expect(result[:settlement]).to include(complete: false, observed_ambiguity: true)
  end

  it '釣銭が保存上限外の場合は預りを実充当額として残さない' do
    result = evidence([ '合計 864円', '現金 1000円', 'お釣り 1000000000000円' ])

    expect(result[:payments]).to contain_exactly(include(method: '現金', amount: nil, printed_amount: 1000, amount_role: 'unknown'))
    expect(result[:settlement]).to include(complete: false, observed_ambiguity: true)
  end

  it '不正な預り釣銭の組があっても独立した印字充当額は保持する' do
    result = evidence([ '合計 864円', '現金支払 864円', 'お預り 1000円', 'お釣り 2000円' ])

    expect(result[:payments]).to contain_exactly(include(method: '現金支払', amount: 864, amount_role: 'applied'))
    expect(result[:settlement][:observed_ambiguity]).to be(true)
  end

  it 'ポイントの利用可能額や未使用や残高を実支払として取得しない' do
    aggregate_failures do
      [ 'ポイント利用可能100円', 'ポイント支払 未使用100円', 'ポイント利用残高100円', 'ポイント利用不可100円', 'ポイント利用なし100円' ].each do |line|
        result = evidence([ '合計 864円', line, 'eGift適用 1000円', '釣銭 0円' ])

        expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: 1000)), line
      end
    end
  end

  it 'structuredのポイント方法が否定や利用可能を表す場合も実支払へ昇格しない' do
    aggregate_failures do
      [ 'ポイント利用可能', 'ポイント支払 未使用', 'ポイント利用残高', 'ポイント利用不可', 'ポイント利用なし' ].each do |method|
        result = evidence([ '合計 864円', 'eGift適用 1000円', '釣銭 0円' ], payments: [ { method: method, amount: 100 } ])

        expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: 1000)), method
      end
    end
  end

  it 'structuredが指すポイント印字が利用可能額なら実支払へ昇格しない' do
    result = evidence(
      [ '合計 864円', 'ポイント利用可能100円', 'eGift適用 1000円', '釣銭 0円' ],
      payments: [
        {
          method: 'ポイント利用',
          amount: 100,
          method_source_line_index: 1,
          method_source_span_start: 0,
          method_source_span_end: 6,
          source_line_index: 1
        }
      ]
    )

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: 1000))
  end

  it '支払と同額でも別印字の裸の金額を重複と決めて精算の完全性を肯定しない' do
    result = evidence([ '合計 864円', 'eGift適用 1000円', '1000円', '釣銭 0円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: 1000))
    expect(result[:settlement]).to include(complete: false, observed_ambiguity: true)
  end

  it '商品直下の0円を除き決済欄の電子ギフト額を充当額と分離する' do
    result = evidence([ '検証品 800円', 'eGift適用 0円', '合計 864円', 'eGift適用 600円', 'eGift適用 400円', '釣銭 0円' ])

    aggregate_failures do
      expect(result[:payments]).to contain_exactly(
        include(method: 'eGift', amount: nil, printed_amount: 600, amount_role: 'voucher_tender', source_line_index: 3),
        include(method: 'eGift', amount: nil, printed_amount: 400, amount_role: 'voucher_tender', source_line_index: 4)
      )
      expect(result[:settlement]).to include(bounded: true, complete: true, ambiguous: false, gift_tender_method_keys: [ 'egift' ])
    end
  end

  it '同額でも別印字の券を保持しstructuredと本文の同一印字だけを除く' do
    result = evidence(
      [ '合計 864円', 'eGift適用 500円', 'eGift適用 500円', '釣銭 0円' ],
      payments: [ { method: 'eGift', amount: 500, method_source_line_index: 1, source_line_index: 1, source_span_start: 8, source_span_end: 11 } ]
    )

    expect(result[:payments]).to contain_exactly(
      include(method: 'eGift', printed_amount: 500, source_line_index: 1),
      include(method: 'eGift', printed_amount: 500, source_line_index: 2)
    )
  end

  it 'structuredで部分取得されても別の印字決済を本文から補完する' do
    result = evidence(
      [ '合計 864円', '現金支払 264円', 'eGift適用 600円', '釣銭 0円' ],
      payments: [ { method: 'Cash', amount: 264, method_source_line_index: 1, source_line_index: 1 } ]
    )

    aggregate_failures do
      expect(result[:payments]).to contain_exactly(
        include(method: 'Cash', amount: 264, amount_role: 'applied'),
        include(method: 'eGift', amount: nil, printed_amount: 600, amount_role: 'voucher_tender')
      )
      expect(result[:settlement][:ambiguous]).to be(false)
    end
  end

  it '直後行と列形式の金額を方法に帰属させる' do
    result = evidence([ '合計 864円', '支払方法', 'eGift適用', '600円', '現金支払     264円', '釣銭 0円' ])

    expect(result[:payments]).to contain_exactly(
      include(method: 'eGift', printed_amount: 600, amount_role: 'voucher_tender', source_line_index: 3),
      include(method: '現金支払', amount: 264, amount_role: 'applied', source_line_index: 4)
    )
  end

  it '方法と金額が別の行の列に並ぶ場合は列順を対応させる' do
    result = evidence([ '合計 864円', '支払方法', 'eGift適用     現金支払', '600円        264円', '釣銭 0円' ])

    expect(result[:payments]).to contain_exactly(
      include(method: 'eGift', amount: nil, printed_amount: 600, source_line_index: 3),
      include(method: '現金支払', amount: 264, source_line_index: 3)
    )
    expect(result[:settlement][:ambiguous]).to be(false)
  end

  it '印字された預りと釣銭から現金の実支払を求める' do
    result = evidence([ '合計 864円', 'お預かり 1000円', '釣銭 136円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'cash', amount: 864, printed_amount: 1000, amount_role: 'cash_settlement'))
    expect(result[:settlement][:ambiguous]).to be(false)
  end

  it '預り額と同じ現金行を独立した充当額として二重保存しない' do
    result = evidence([ '合計 864円', '現金 1000円', 'お預かり 1000円', '釣銭 136円' ])

    expect(result[:payments]).to contain_exactly(include(method: '現金', amount: 864, amount_role: 'cash_settlement'))
  end

  it '単独の現金預り表記と釣銭から実充当額を求め印字spanを借用しない' do
    result = evidence([ '合計 770円', '現金 1000円', 'お釣り 230円' ])

    expect(result[:payments]).to contain_exactly(
      include(
        method: '現金',
        amount: 770,
        printed_amount: 1000,
        amount_role: 'cash_settlement',
        source_span_start: nil,
        source_span_end: nil
      )
    )
  end

  it '電子ギフトのお預りと釣銭を現金の充当額へ変換しない' do
    result = evidence([ '合計 1000円', 'eGiftお預り 1200円', '釣銭 200円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: 1200, amount_role: 'voucher_tender'))
    expect(result[:payments]).not_to include(include(method_identity: 'cash'))
    expect(result[:settlement]).to include(complete: false, ambiguous: true)
  end

  it '見出しがなくても独立した現金預りと釣銭の証拠を欠損境界と区別する' do
    result = evidence([ 'お預り 1000円', '釣銭 400円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'cash', amount: 600, amount_role: 'cash_settlement'))
    expect(result[:settlement]).to include(bounded: false, complete: false, ambiguous: true, observed_ambiguity: false)
  end

  it '見出しがなくても未分類の実決済が残る場合は現金の一部だけを精算全額にしない' do
    result = evidence([ 'お預り 1000円', '釣銭 400円', 'StarPay支払 400円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'cash', amount: 600, amount_role: 'cash_settlement'))
    expect(result[:settlement]).to include(bounded: false, complete: false, observed_ambiguity: true)
  end

  it 'methodのsource行が異なる手段を指すstructured情報は矛盾として扱う' do
    result = evidence(
      [ '合計 864円', 'eGift適用 1000円', '釣銭 0円' ],
      payments: [ { method: 'Cash', amount: 1000, method_source_line_index: 1, source_line_index: 1 } ]
    )

    expect(result[:settlement][:ambiguous]).to be(true)
    expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: 1000))
  end

  it 'カード売上票の識別コードを金額にせず金額ラベルと直後行を帰属させる' do
    result = evidence([ 'クレジットカード売上票', 'カード会社', 'Mastercard(307)', '金額', '864', '合計金額', '864' ])

    expect(result[:payments]).to contain_exactly(include(method: 'Mastercard', amount: 864, source_line_index: 4))
    expect(result[:settlement][:ambiguous]).to be(false)
  end

  it '方法だけ取得できた決済は金額nilのまま保持する' do
    result = evidence([ '合計 864円', '支払方法', 'eGift利用', '釣銭 0円' ])

    aggregate_failures do
      expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: nil, amount_role: 'unknown'))
      expect(result[:settlement][:ambiguous]).to be(true)
    end
  end

  it '明示0円を金額欠損と区別する' do
    result = evidence([ '合計 864円', '現金支払 0円', 'eGift適用 1000円', '釣銭 0円' ])

    expect(result[:payments]).to include(include(method: '現金支払', amount: 0, amount_role: 'applied'))
    expect(result[:settlement][:ambiguous]).to be(false)
  end

  it '明示された充当額は額面と区別して独立した金額にする' do
    result = evidence([ '合計 864円', '商品券充当額 600円', '現金支払 264円' ])

    expect(result[:payments]).to include(include(method: '商品券', amount: 600, printed_amount: 600, amount_role: 'applied'))
  end

  it 'otherに属する異なる手段を同じ集約キーにしない' do
    result = evidence([ '合計 864円', 'eGift適用 600円', 'ストアクレジット利用 264円', '釣銭 0円' ])

    expect(result[:payments].map { |payment| payment[:method_identity] }).to eq(%w[other other])
    expect(result[:payments].map { |payment| payment[:settlement_method_key] }.uniq.size).to eq(2)
  end

  it '広告と商品券販売を決済にしない' do
    result = evidence([ '商品券販売 1000円', 'eGiftが使えます', '合計 1000円', '現金支払 1000円', 'eGift対応' ])

    expect(result[:payments]).to contain_exactly(include(method: '現金支払', amount: 1000))
  end

  it 'structuredが商品券販売の印字を支払とした場合も保存対象から除く' do
    result = evidence(
      [ '商品券販売 1000円', '合計 1000円', '現金支払 1000円', '釣銭 0円' ],
      payments: [ { method: '商品券', amount: 1000, method_source_line_index: 0, source_line_index: 0 } ]
    )

    expect(result[:payments]).to contain_exactly(include(method: '現金支払', amount: 1000))
  end

  it 'structuredの支払候補が商品明細の金額sourceへ帰属する場合は商品を優先する' do
    result = evidence(
      [ 'eGiftカード', '1000円', '合計 1000円', '現金支払 1000円', '釣銭 0円' ],
      payments: [ { method: 'eGift', amount: 1000, method_source_line_index: 0, source_line_index: 1 } ],
      items: [ { raw_text: 'eGiftカード', line_total: 1000, source_line_index: 1 } ]
    )

    expect(result[:payments]).to contain_exactly(include(method: '現金支払', amount: 1000))
  end

  it '物理sourceと手段が一致する場合はstructuredの方法表記を保持する' do
    result = evidence(
      [ '合計 864円', 'suica支払 864円', '釣銭 0円' ],
      payments: [ { method: 'Suica支払', amount: 864, method_source_line_index: 1, source_line_index: 1 } ]
    )

    expect(result[:payments]).to contain_exactly(include(method: 'Suica支払', amount: 864))
    expect(result[:settlement][:ambiguous]).to be(false)
  end

  it '合計や支払欄が欠けたレシートの商品直下0円を決済にしない' do
    result = evidence(
      [ '検証品 800円', 'eGift適用 0円' ],
      payments: [ { method: 'eGift', amount: 0, method_source_line_index: 1, source_line_index: 1 } ]
    )

    expect(result[:payments]).to eq([])
    expect(result[:settlement]).to include(bounded: false, complete: false)
  end

  it 'structuredのsourceが不明な同額別決済を方法と金額だけで消さない' do
    result = evidence(
      [ '合計 864円', '釣銭 0円' ],
      payments: [ { method: 'Cash', amount: 432 }, { method: 'Cash', amount: 432 } ]
    )

    expect(result[:payments].size).to eq(2)
    expect(result[:payments].map { |payment| payment[:amount] }).to eq([ 432, 432 ])
  end

  it '商品と決済欄の境界がない電子ギフトを残額配賦の根拠にしない' do
    result = evidence([ '検証品 864円', 'eGift適用 1000円', '釣銭 0円' ])

    expect(result[:settlement]).to include(bounded: false, complete: false, ambiguous: true)
  end

  it '肯定的な利用行があっても閉じた決済欄を確認できなければ残額配賦しない' do
    result = evidence([ '合計 864円', 'eGift適用 1000円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: 1000))
    expect(result[:settlement]).to include(bounded: true, complete: false)
  end

  it '決済欄より前の釣銭を後続精算の閉じる根拠に使わない' do
    result = evidence([ '釣銭 0円', '合計 864円', 'eGift適用 1000円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', printed_amount: 1000))
    expect(result[:settlement][:complete]).to be(false)
  end

  it '精算の終了行より後の別支払を商品券の残額計算へ混ぜない' do
    result = evidence([ '合計 864円', 'eGift適用 1000円', 'ありがとうございました', '現金支払 300円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', printed_amount: 1000))
    expect(result[:settlement]).to include(complete: true, ambiguous: false)
  end

  it '残高表記に返金が混在しても情報行として除外しない' do
    result = evidence([ '合計 864円', 'eGift適用 1000円', '残高返金 136円', '釣銭 0円' ])

    expect(result[:settlement]).to include(complete: false, ambiguous: true)
  end

  it '対象という文字だけで未分類の決済行を税情報として除外しない' do
    result = evidence([ '合計 864円', 'eGift適用 1000円', '不明決済対象 300円', '釣銭 0円' ])

    expect(result[:settlement]).to include(complete: false, ambiguous: true)
  end

  it '明示された税summary直後の金額と識別番号を別支払として扱わない' do
    result = evidence([
      '合計 999円', 'PayPay支払 999円', '(税率8%対象', '¥301)', '(税率10%対象', '¥0)',
      '(内消費税等8%', '¥22)', '(内消費税等10%', '¥54)', '処理番号', '5281948821', '釣銭 0円'
    ])

    expect(result[:payments]).to contain_exactly(include(method: 'PayPay支払', amount: 999))
    expect(result[:settlement]).to include(complete: true, ambiguous: false)
  end

  it '税の見出しと軽減税率に帰属する対象額と税額を精算の競合にしない' do
    result = evidence([ 'お預かり', '6000', 'お釣り', '-720', '合計', '税', '軽8%', '¥5280', '¥391' ])

    expect(result[:payments]).to contain_exactly(include(method: 'cash', amount: 5280, amount_role: 'cash_settlement'))
    expect(result[:settlement][:observed_ambiguity]).to be(false)
  end

  it '税の対象額と税額の位置に未分類決済が混在すれば除外しない' do
    result = evidence([ '合計 864円', 'eGift適用 1000円', '税', '軽8%', '¥800', 'StarPay支払 300円', '釣銭 0円' ])

    expect(result[:settlement][:observed_ambiguity]).to be(true)
  end

  it '税blockを注入profileで認識し旧見出しへ直接依存しない' do
    replacement = ReceiptAnalysisProfiles.default.dup
    allow(replacement).to receive(:analysis_payment_tax_block_heading_pattern).and_return(/\A検証税\z/)
    allow(replacement).to receive(:analysis_payment_tax_block_rate_pattern).and_return(/\A検証税率8%\z/)
    prefix = [ 'お預り 1000円', '釣銭 400円', '合計' ]
    recognized = evidence(prefix + [ '検証税', '検証税率8%', '¥600', '¥44' ], profile: replacement)
    old = evidence(prefix + [ '税', '軽8%', '¥600', '¥44' ], profile: replacement)

    expect(recognized[:settlement][:observed_ambiguity]).to be(false)
    expect(old[:settlement][:observed_ambiguity]).to be(true)
  end

  it '税summaryや識別番号の見出し直後でも未分類の決済行を除外しない' do
    tax = evidence([ '合計 864円', 'eGift適用 1000円', '(税率8%対象', 'StarPay支払 300円', '釣銭 0円' ])
    metadata = evidence([ '合計 864円', 'eGift適用 1000円', '処理番号', 'StarPay支払 300円', '釣銭 0円' ])

    expect(tax[:settlement][:ambiguous]).to be(true)
    expect(metadata[:settlement][:ambiguous]).to be(true)
  end

  it 'structuredに方法不明の決済金額が残れば商品券単独精算にしない' do
    result = evidence([ '合計 864円', 'eGift適用 1000円', '釣銭 0円' ], payments: [ { method: nil, amount: 264 } ])

    expect(result[:settlement]).to include(complete: false, ambiguous: true)
  end

  it '方法が欠けたstructuredでも正確な同一印字tokenへ帰属すれば別決済としない' do
    result = evidence(
      [ '合計 864円', 'eGift適用 1000円', '釣銭 0円' ],
      payments: [ { method: nil, amount: 1000, source_line_index: 1, source_span_start: 8, source_span_end: 12 } ]
    )

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: 1000))
    expect(result[:settlement]).to include(complete: true, ambiguous: false)
  end

  it 'structuredの欠損金額を同一印字の本文金額に対する反証にしない' do
    result = evidence(
      [ '合計 864円', 'eGift適用 1000円', '釣銭 0円' ],
      payments: [ { method: 'eGift', amount: nil, method_source_line_index: 1 } ]
    )

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', printed_amount: 1000))
    expect(result[:settlement]).to include(complete: true, ambiguous: false)
  end

  it '同じ分類でも印字と異なるカードブランドへ方法を書き換えない' do
    result = evidence(
      [ '合計 864円', 'VISA支払 864円', '釣銭 0円' ],
      payments: [ { method: 'Mastercard', amount: 864, method_source_line_index: 1, source_line_index: 1 } ]
    )

    expect(result[:payments]).to contain_exactly(include(method: 'VISA支払', amount: 864))
    expect(result[:settlement][:ambiguous]).to be(true)
  end

  it '同じother分類でも印字にない別の券を補完しない' do
    result = evidence(
      [ '合計 864円', 'ストアクレジット利用 1000円', '釣銭 0円' ],
      payments: [ { method: 'eGift', amount: 1000, method_source_line_index: 1, source_line_index: 1 } ]
    )

    expect(result[:payments]).to contain_exactly(include(method: 'ストアクレジット', amount: nil, printed_amount: 1000))
    expect(result[:settlement][:ambiguous]).to be(true)
  end

  it '同一行の同じ方法に帰属する金額をstructuredの印字spanで区別する' do
    result = evidence(
      [ '合計 864円', 'eGift適用     eGift適用', '600円        400円', '釣銭 0円' ],
      payments: [
        {
          method: 'eGift',
          amount: 400,
          method_source_line_index: 1,
          method_source_span_start: 12,
          method_source_span_end: 17,
          source_line_index: 2,
          source_span_start: 12,
          source_span_end: 15
        }
      ]
    )

    expect(result[:payments].map { |payment| payment[:printed_amount] }).to eq([ 600, 400 ])
    expect(result[:settlement][:ambiguous]).to be(false)
  end

  it 'structuredのポイント支払額はポイント数に変換せず円金額として保持する' do
    result = evidence([ '合計 864円' ], payments: [ { method: 'ポイント利用', amount: 300 }, { method: 'VISA Credit', amount: 564 } ])

    expect(result[:payments]).to contain_exactly(
      include(method: 'ポイント利用', amount: 300, method_identity: 'point'), include(method: 'VISA Credit', amount: 564)
    )
  end

  it '肯定的な利用根拠がないブランド名や額面を単独精算にしない' do
    result = evidence([ '合計 864円', 'eGift額面 1000円', '釣銭 0円' ])

    expect(result[:settlement][:ambiguous]).to be(true)
  end

  it '使用を肯定する決済印字なら最終金額へ実充当額を確定する' do
    result = evidence([ '合計 864円', 'eGift使用 1000円', '釣銭 0円' ])
    amount_result = ReceiptAmountService.call(
      receipt: { subtotal_amount: 800, tax_amount: 64, total_amount: 864 },
      receipt_items: [ { price: 800, quantity: 1, line_total: 800, tax_rate: BigDecimal('0.08') } ],
      receipt_tax_details: [ { description: '外税8%', rate: BigDecimal('0.08'), net_amount: 800, amount: 64 } ],
      context: :analysis
    )
    params = {
      receipt_attributes: { total_amount: 864, payment_method: 'other' },
      receipt_payments_attributes: result[:payments].map { |payment| payment.slice(:method, :amount) },
      payment_evidence: result
    }

    finalized = Analysis.finalize_payments(params: params, amount_result: amount_result)

    expect(result[:settlement]).to include(complete: true, ambiguous: false)
    expect(finalized[:receipt_payments_attributes]).to eq([ { method: 'eGift', amount: 864 } ])
  end

  it '否定や使用可能の印字をsource付きstructuredからも実決済へ昇格しない' do
    labels = [
      '未利用',
      '未使用',
      '未適用',
      '未充当',
      '未支払',
      '未払い',
      '未決済',
      '未精算',
      '不使用',
      '使用なし',
      '使用不可',
      '使用可',
      '使用可能',
      '利用なし',
      '利用不可',
      'unused',
      'unpaid',
      'unredeemed',
      'not paid',
      'not used',
      'not redeemed',
      'not applied'
    ]

    aggregate_failures do
      labels.each do |label|
        result = evidence(
          [ '合計 864円', "eGift #{label} 1000円", '釣銭 0円' ],
          payments: [
            {
              method: 'eGift',
              amount: 1000,
              method_source_line_index: 1,
              method_source_span_start: 0,
              method_source_span_end: 5,
              source_line_index: 1
            }
          ]
        )

        expect(result[:payments]).to eq([]), label
        expect(result[:settlement][:complete]).to be(false), label
      end
    end
  end

  it '否定の除外条件も注入profileから取得し旧語彙を直接使わない' do
    replacement = ReceiptAnalysisProfiles.default.dup
    allow(replacement).to receive(:analysis_payment_sale_or_promo_pattern).and_return(/blocked/i)
    blocked = evidence([ '合計 864円', 'eGift blocked 1000円', '釣銭 0円' ], profile: replacement)
    old = evidence([ '合計 864円', 'eGift未利用 1000円', '釣銭 0円' ], profile: replacement)

    expect(blocked[:payments]).to eq([])
    expect(old[:payments]).to contain_exactly(include(method_identity: 'other', printed_amount: 1000))
  end

  it '未分類の金額行が決済欄に残る場合は残額配賦を禁止する' do
    result = evidence([ '合計 864円', 'eGift適用 600円', '別決済 264円', '釣銭 0円' ])

    expect(result[:settlement][:ambiguous]).to be(true)
  end

  it '返金と正の釣銭が競合する場合は残額配賦を禁止する' do
    refund = evidence([ '合計 864円', 'eGift適用 1000円', '返金 136円', '釣銭 0円' ])
    change = evidence([ '合計 864円', 'eGift適用 1000円', '釣銭 136円' ])

    expect(refund[:settlement][:ambiguous]).to be(true)
    expect(change[:settlement][:ambiguous]).to be(true)
  end

  it '支払調整の印字をgift額へ混ぜず金額未取得の調整は不確定とする' do
    result = evidence([ '合計 864円', 'ポイント利用 -64円', 'eGift適用 1000円', '釣銭 0円' ])
    missing = evidence([ '合計 864円', 'ポイント利用', 'eGift適用 1000円', '釣銭 0円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', printed_amount: 1000))
    expect(result[:settlement][:ambiguous]).to be(false)
    expect(missing[:settlement][:ambiguous]).to be(true)
  end

  it '商品券と併用した円金額付きポイント支払を確定した独立の支払として保持する' do
    result = evidence([ '合計 864円', 'ポイント支払 300P ¥300', 'eGift適用 600円', '釣銭 0円' ])

    expect(result[:payments]).to contain_exactly(
      include(method: 'ポイント支払', amount: 300, method_identity: 'point', amount_role: 'applied'),
      include(method: 'eGift', amount: nil, printed_amount: 600, method_identity: 'other')
    )
    expect(result[:settlement]).to include(complete: true, ambiguous: false)
  end

  it 'OCR断片の電子ギフト額を合計に補完しない' do
    result = evidence([ '合計 864円', 'eGift適用 ¥8 4', '釣銭 0円' ])

    expect(result[:payments]).to contain_exactly(include(method: 'eGift', amount: nil, printed_amount: nil, amount_role: 'unknown'))
    expect(result[:settlement][:ambiguous]).to be(true)
  end

  it '負数と永続上限外の決済を通常金額にしない' do
    negative = evidence([ '合計 864円', 'eGift適用 -1000円', '釣銭 0円' ])
    excessive = evidence([ '合計 864円', 'eGift適用 1000000000000円', '釣銭 0円' ])

    expect(negative[:payments]).to include(include(amount: nil, printed_amount: nil, amount_role: 'unknown'))
    expect(excessive[:payments]).to include(include(amount: nil, printed_amount: nil, amount_role: 'unknown'))
    expect(negative[:settlement][:ambiguous]).to be(true)
    expect(excessive[:settlement][:ambiguous]).to be(true)
  end

  it '不正なstructured行と非有限金額を通常の充当額にしない' do
    result = evidence([ '合計 864円', '釣銭 0円' ], payments: [ 1, nil, { method: 'Cash', amount: Float::NAN } ], items: [ 1 ])

    expect(result[:payments]).to contain_exactly(include(method: 'Cash', amount: nil, amount_role: 'unknown'))
    expect(result[:settlement][:ambiguous]).to be(true)
  end

  it 'profileを差し替えると旧語彙を使わず新語彙だけを抽出する' do
    replacement = ReceiptAnalysisProfiles.default.dup
    allow(replacement).to receive(:analysis_voucher_payment_pattern).and_return(/TokenCredit/i)
    allow(replacement).to receive(:analysis_fallback_payment_line_pattern).and_return(/TokenCredit/i)
    allow(replacement).to receive(:fallback_payment_method_patterns).and_return('other' => [ /TokenCredit/i ])
    allow(replacement).to receive(:analysis_payment_affirmative_pattern).and_return(/redeemed/i)
    allow(replacement).to receive(:analysis_payment_method_suffix_pattern).and_return(/redeemed/i)

    result = evidence([ '合計 864円', 'TokenCredit redeemed 1000円', 'eGift適用 1000円', '釣銭 0円' ], profile: replacement)

    expect(result[:payments]).to contain_exactly(include(method: 'TokenCredit', amount_role: 'voucher_tender'))
    expect(result[:settlement][:ambiguous]).to be(true)
  end
end
