# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe UserNumericInput do
  describe ".integer" do
    it "通常数字、3桁区切り、全角数字、符号を明示的に受け入れる" do
      aggregate_failures do
        expect(described_class.integer("001")).to eq(1)
        expect(described_class.integer("1,000")).to eq(1000)
        expect(described_class.integer("１，０００")).to eq(1000)
        expect(described_class.integer("-10")).to eq(-10)
      end
    end

    it "科学表記、文字混在、小数、通貨記号を拒否する" do
      %w[1e2 12abc abc12 1.5 ¥100 ￥１００].each do |value|
        expect { described_class.integer(value) }
          .to raise_error(UserNumericInput::InvalidValue), value
      end
    end

    it "符号を許可しない入力契約を選べる" do
      %w[+1 -1].each do |value|
        expect { described_class.integer(value, signed: false) }
          .to raise_error(UserNumericInput::InvalidValue), value
      end
    end

    it "巨大Integerを文字列化する前に拒否する" do
      expect {
        Timeout.timeout(1) { described_class.integer(2**10_000) }
      }.to raise_error(UserNumericInput::InvalidValue, "Invalid user numeric input")
    end
  end

  describe ".decimal" do
    it "通常小数、途中表現、3桁区切り、全角数字を明示的に受け入れる" do
      aggregate_failures do
        expect(described_class.decimal("1.5")).to eq(BigDecimal("1.5"))
        expect(described_class.decimal(".5")).to eq(BigDecimal("0.5"))
        expect(described_class.decimal("1.")).to eq(BigDecimal("1"))
        expect(described_class.decimal("1,000.5")).to eq(BigDecimal("1000.5"))
        expect(described_class.decimal("１．５")).to eq(BigDecimal("1.5"))
      end
    end

    it "科学表記、文字混在、誤った区切り、通貨記号を拒否する" do
      %w[1e2 12abc abc12 1,00.5 1.2.3 ¥1.5].each do |value|
        expect { described_class.decimal(value) }
          .to raise_error(UserNumericInput::InvalidValue), value
      end
    end

    it "レシート数量だけで使うdecimal comma契約を分離する" do
      aggregate_failures do
        expect(described_class.decimal("0,300", signed: false, decimal_comma: true)).to eq(BigDecimal("0.3"))
        expect(described_class.decimal("1,000", signed: false, decimal_comma: true)).to eq(BigDecimal("1"))
        expect { described_class.decimal("-0,300", signed: false, decimal_comma: true) }
          .to raise_error(UserNumericInput::InvalidValue)
      end
    end

    it "ASCIIの外側空白だけをstripし、U+3000とNBSPを入力文字として拒否する" do
      aggregate_failures do
        expect(described_class.decimal(" \t1.5\r\n")).to eq(BigDecimal("1.5"))
        expect { described_class.decimal("\u30001.5\u3000") }
          .to raise_error(UserNumericInput::InvalidValue)
        expect { described_class.decimal("\u00a01.5\u00a0") }
          .to raise_error(UserNumericInput::InvalidValue)
      end
    end

    it "128 bytesまでの入力を維持し、それを超える数値文字列をBigDecimal化せず拒否する" do
      boundary = "9" * described_class::MAX_INPUT_BYTES
      oversized = "9" * 100_000

      aggregate_failures do
        expect(described_class.decimal(boundary)).to eq(BigDecimal(boundary))
        expect {
          Timeout.timeout(1) { described_class.decimal(oversized) }
        }.to raise_error(UserNumericInput::InvalidValue, "Invalid user numeric input")
      end
    end

    it "巨大BigDecimalと非scalar入力を文字列化せず拒否する" do
      aggregate_failures do
        expect {
          Timeout.timeout(1) { described_class.decimal(BigDecimal("1E100000")) }
        }.to raise_error(UserNumericInput::InvalidValue, "Invalid user numeric input")
        expect {
          Timeout.timeout(1) { described_class.decimal(BigDecimal("9" * 1_000)) }
        }.to raise_error(UserNumericInput::InvalidValue, "Invalid user numeric input")

        [ [], {} ].each do |value|
          expect(value).not_to receive(:to_s)
          expect { described_class.decimal(value) }
            .to raise_error(UserNumericInput::InvalidValue, "Invalid user numeric input")
        end
      end
    end

    it "invalid encodingを正規化前に拒否し、既存のscalar入力を維持する" do
      invalid = "\xFF".b.force_encoding(Encoding::UTF_8)

      aggregate_failures do
        expect { described_class.decimal(invalid) }
          .to raise_error(UserNumericInput::InvalidValue, "Invalid user numeric input")
        expect(described_class.decimal(BigDecimal("1.5"))).to eq(BigDecimal("1.5"))
        expect(described_class.decimal(1.5)).to eq(BigDecimal("1.5"))
      end
    end
  end
end
