require "rails_helper"

RSpec.describe "Receipts::IdentifierInput" do
  subject(:input_boundary) { Receipts.const_get(:IdentifierInput, false) }

  let(:source_path) { Rails.root.join("app/forms/receipts/identifier_input.rb") }

  def parse(value)
    input_boundary.call(value)
  end

  def expect_result(result, kind:, value:, malformed:)
    aggregate_failures do
      expect(result).to be_a(Data)
      expect(result).to be_frozen
      expect(result.kind).to eq(kind)
      expect(result.value).to eq(value)
      expect(result.value).to be_frozen if result.value
      expect(result.malformed?).to eq(malformed)
    end
  end

  it "standard Form autoload pathから提供する" do
    expect(source_path).to exist
    expect(Rails.autoloaders.main.cpath_expected_at(source_path)).to eq("Receipts::IdentifierInput")
  end

  describe ".call" do
    context "with a display ID" do
      it "正式なuppercase形式をdisplay IDとして返す" do
        expect_result(
          parse("R-A1B2C3"),
          kind: :display_id,
          value: "R-A1B2C3",
          malformed: false
        )
      end

      it "lowercase入力だけを比較用にuppercase化する" do
        expect_result(
          parse("r-a1b2c3"),
          kind: :display_id,
          value: "R-A1B2C3",
          malformed: false
        )
      end

      it "前後のASCII空白をtrimする" do
        expect_result(
          parse(" \tR-a1b2c3\n"),
          kind: :display_id,
          value: "R-A1B2C3",
          malformed: false
        )
      end

      it "callerの入力Stringを変更もfreezeもしない" do
        input = +" \tR-a1b2c3\n"
        original = input.dup
        result = parse(input)

        aggregate_failures do
          expect(input).to eq(original)
          expect(input).not_to be_frozen
          expect(result.value).not_to equal(input)
        end
      end

      it "partial、prefixだけ、長さ違い、許可外文字、wildcardをmalformedにする" do
        malformed_values = [
          "R-ABC",
          "R-",
          "R-ABC12",
          "R-ABC1234",
          "R-AB!123",
          "R-AB*123"
        ]

        aggregate_failures do
          malformed_values.each do |value|
            expect_result(parse(value), kind: nil, value: nil, malformed: true)
          end
        end
      end

      it "internal numeric IDやpublic IDをdisplay IDと誤判定しない" do
        numeric_result = parse("123")
        public_result = parse("rcpt_AbCdEf1234567890")

        aggregate_failures do
          expect_result(numeric_result, kind: nil, value: nil, malformed: false)
          expect_result(
            public_result,
            kind: :public_id,
            value: "rcpt_AbCdEf1234567890",
            malformed: false
          )
        end
      end
    end

    context "with a public ID" do
      it "正式な形式をcaseを保持したpublic IDとして返す" do
        value = "rcpt_AbCdEf1234567890"

        expect_result(parse(value), kind: :public_id, value: value, malformed: false)
      end

      it "前後のASCII空白をtrimしてもsuffixのcaseを変えない" do
        value = "rcpt_aBcDeF0987654321"

        expect_result(
          parse(" \t#{value}\n"),
          kind: :public_id,
          value: value,
          malformed: false
        )
      end

      it "uppercase prefixを勝手に正規化しない" do
        expect_result(
          parse("RCPT_AbCdEf1234567890"),
          kind: nil,
          value: nil,
          malformed: true
        )
      end

      it "partial、長さ違い、許可外文字、wildcardをmalformedにする" do
        malformed_values = [
          "rcpt_",
          "rcpt_AbCd",
          "rcpt_AbCdEf123456789",
          "rcpt_AbCdEf12345678901",
          "rcpt_AbCdEf123456789!",
          "rcpt_AbCdEf123456789*"
        ]

        aggregate_failures do
          malformed_values.each do |value|
            expect_result(parse(value), kind: nil, value: nil, malformed: true)
          end
        end
      end

      it "display IDをpublic IDと誤判定しない" do
        expect_result(
          parse("R-A1B2C3"),
          kind: :display_id,
          value: "R-A1B2C3",
          malformed: false
        )
      end
    end

    context "with generic or abnormal input" do
      it "nil、blank、non-String、internal ID、通常textをunknownとして安全に扱う" do
        object = Object.new
        object.define_singleton_method(:to_s) { raise "must not coerce arbitrary objects" }
        values = [ nil, "", " \t\n", 123, [], {}, object, "123", "レシート" ]

        aggregate_failures do
          values.each do |value|
            result = nil
            expect { result = parse(value) }.not_to raise_error
            expect_result(result, kind: nil, value: nil, malformed: false)
          end
        end
      end

      it "Unicode case foldでdisplay IDへ化ける入力をrejectする" do
        expect_result(
          parse("R-ſ23456"),
          kind: nil,
          value: nil,
          malformed: true
        )
      end

      it "前後または内部にnull byteを含むID-like inputを例外なくmalformedにする" do
        values = [
          "\0R-A1B2C3",
          "R-A1B2C3\0",
          "R-AB\0C12",
          "\0rcpt_AbCdEf1234567890",
          "rcpt_AbCdEf1234567890\0"
        ]

        aggregate_failures do
          values.each do |value|
            result = nil
            expect { result = parse(value) }.not_to raise_error
            expect_result(result, kind: nil, value: nil, malformed: true)
          end
        end
      end

      it "不正encodingを例外なくmalformedにする" do
        invalid = "R-\xFF".b.force_encoding(Encoding::UTF_8)
        result = nil

        expect { result = parse(invalid) }.not_to raise_error
        expect_result(result, kind: nil, value: nil, malformed: true)
      end

      it "raw inputを32 bytesへboundし、trim後のcanonical public IDだけを受理する" do
        public_id = "rcpt_AbCdEf1234567890"
        within_bound = "#{" " * 5}#{public_id}#{" " * 6}"
        over_bound = "#{" " * 5}#{public_id}#{" " * 7}"

        aggregate_failures do
          expect(within_bound.bytesize).to eq(32)
          expect_result(parse(within_bound), kind: :public_id, value: public_id, malformed: false)
          expect(over_bound.bytesize).to eq(33)
          expect_result(parse(over_bound), kind: nil, value: nil, malformed: true)
        end
      end

      it "極端に長い文字列をencoding確認や正規化の前にbounded rejectする" do
        max_input_bytes = input_boundary.const_get(:MAX_INPUT_BYTES, false)
        guarded_string_class = Class.new(String) do
          def valid_encoding?
            raise "over-bound input encoding must not be inspected"
          end

          def encoding
            raise "over-bound input encoding must not be inspected"
          end

          def strip
            raise "over-bound input must not be stripped"
          end

          def ascii_only?
            raise "over-bound input must not be inspected"
          end

          def upcase(*)
            raise "over-bound input must not be normalized"
          end
        end
        value = guarded_string_class.new("R-#{"A" * 1_000_000}")
        result = nil

        expect(max_input_bytes).to eq(32)
        expect { result = parse(value) }.not_to raise_error
        expect_result(result, kind: nil, value: nil, malformed: true)
      end

      it "identifier-like malformedと通常のnon-identifierを区別する" do
        malformed_result = parse("r-*12345")
        non_identifier_result = parse("coffee")

        aggregate_failures do
          expect_result(malformed_result, kind: nil, value: nil, malformed: true)
          expect_result(non_identifier_result, kind: nil, value: nil, malformed: false)
        end
      end

      it "呼び出し順に依存せず同じ入力へ同じResultを返す" do
        first = parse(" r-a1b2c3 ")
        parse("rcpt_AbCdEf1234567890")
        second = parse(" r-a1b2c3 ")

        expect(second).to eq(first)
      end
    end
  end

  describe "architecture boundary" do
    it "scalar value以外のcontext引数を受け取らない" do
      expect(input_boundary.method(:call).parameters).to eq([ [ :req, :value ] ])
    end

    it "resolverや検索を追加せずcallだけをpublic singleton APIにする" do
      expect(input_boundary.singleton_methods(false)).to contain_exactly(:call)
    end

    it "immutableな最小Result contractだけを返す" do
      result = parse("R-A1B2C3")

      aggregate_failures do
        expect(input_boundary::Result).to be < Data
        expect(input_boundary::Result.members).to eq([ :kind, :value, :malformed ])
        expect(result.class).to eq(input_boundary::Result)
        expect(result.to_h.values).not_to include(be_a(ActiveRecord::Relation))
        expect(result.to_h.values).not_to include(be_a(ApplicationRecord))
      end
    end

    it "DB queryを実行しない" do
      queries = []
      callback = lambda do |_name, _started, _finished, _id, payload|
        next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name].to_s)

        queries << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        [ "R-A1B2C3", "rcpt_AbCdEf1234567890", "R-*", "coffee", nil, [] ].each do |value|
          parse(value)
        end
      end

      expect(queries).to be_empty
    end

    it "Receipt format定数以外のDB・scope・authorization・response contextへ依存しない" do
      source = source_path.read

      aggregate_failures do
        expect(source.scan(/Receipt::[A-Z_]+/).uniq).to contain_exactly(
          "Receipt::DISPLAY_ID_FORMAT",
          "Receipt::DISPLAY_ID_PREFIX",
          "Receipt::PUBLIC_ID_FORMAT",
          "Receipt::PUBLIC_ID_PREFIX"
        )
        expect(source).not_to match(
          /\b(?:ActiveRecord|ApplicationRecord|ReceiptAnalysisRun|User|Admin|Current|ActionController)\b/
        )
        expect(source).not_to match(/\bReceipt\./)
        expect(source).not_to match(/\b(?:render|redirect_to|head)\b/)
      end
    end
  end
end
