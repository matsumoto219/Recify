require 'rails_helper'

RSpec.describe Amounts::ItemQuantitySemantics do
  describe 'quantity role separation' do
    it 'purchased quantity, reference quantity, and package contentを別々に保持する' do
      package_content = :opaque_package_evidence

      semantics = described_class.new(
        purchased_quantity: '2',
        purchased_unit_code: 'bag',
        reference_quantity: '100',
        reference_unit_code: 'gram',
        package_content: package_content
      )

      aggregate_failures do
        expect(semantics.purchased_quantity).to eq('2')
        expect(semantics.purchased_unit).to have_attributes(status: :known, code: 'bag', raw: 'bag')
        expect(semantics.reference_quantity).to eq('100')
        expect(semantics.reference_unit).to have_attributes(status: :known, code: 'gram', raw: 'gram')
        expect(semantics.package_content).to eq(package_content)
        expect(semantics.package_content).to equal(package_content)
        expect(semantics).to be_frozen
        expect(semantics.package_content).to be_frozen
      end
    end

    it 'package-only情報をreference pricing sourceとして扱わない' do
      semantics = described_class.new(
        package_content: :opaque_package_evidence
      )

      aggregate_failures do
        expect(semantics).to be_package_only
        expect(semantics).not_to be_reference_basis_complete
        expect { semantics.validate_reference_formula! }
          .to raise_error(described_class::InvalidFormulaSourceError)
      end
    end

    it '入力hashやnested valueを変更しない' do
      attributes = {
        purchased_quantity: +'1.5',
        purchased_unit_code: +'liter',
        reference_quantity: +'500',
        reference_unit_code: +'milliliter',
        package_content: { opaque: [ +'package evidence' ] }
      }
      original = attributes.deep_dup

      semantics = described_class.new(**attributes)

      aggregate_failures do
        expect(attributes).to eq(original)
        expect(attributes[:purchased_quantity]).not_to be_frozen
        expect(attributes.dig(:package_content, :opaque).first).not_to be_frozen
        expect(semantics.purchased_quantity).to be_frozen
        expect(semantics.package_content[:opaque]).to be_frozen
        expect(semantics.package_content[:opaque].first).to be_frozen
      end
    end

    it 'deep-copyできないmutable custom objectをpackage contentに受け付けない' do
      mutable_evidence = Object.new

      expect do
        described_class.new(package_content: mutable_evidence)
      end.to raise_error(described_class::InvalidPackageContentError)
      expect(mutable_evidence).not_to be_frozen
    end

    it 'mutable Numeric subclassをquantityやpackage contentに受け付けない' do
      mutable_numeric_class = Class.new(Numeric) { attr_accessor :value }
      mutable_numeric = mutable_numeric_class.new
      mutable_numeric.value = 1

      aggregate_failures do
        expect {
          described_class.new(purchased_quantity: mutable_numeric, purchased_unit_code: 'each')
        }.to raise_error(described_class::InvalidFormulaSourceError)
        expect {
          described_class.new(package_content: mutable_numeric)
        }.to raise_error(described_class::InvalidPackageContentError)
        expect(mutable_numeric).not_to be_frozen
      end
    end
  end

  describe 'strict unit resolution' do
    it 'canonical codeと既知aliasをknownとして保持する' do
      semantics = described_class.new(
        purchased_quantity: '1.5',
        purchased_unit_code: ' L ',
        reference_quantity: '500',
        reference_unit_code: ' ml '
      )

      aggregate_failures do
        expect(semantics.purchased_unit).to have_attributes(status: :known, code: 'liter', raw: 'L')
        expect(semantics.reference_unit).to have_attributes(status: :known, code: 'milliliter', raw: 'ml')
        expect(semantics).to be_reference_basis_complete
        expect(semantics.validate_reference_formula!).to equal(semantics)
      end
    end

    it 'blankとunknownをeachへfallbackせず区別する' do
      blank = described_class.new(
        purchased_quantity: '1',
        purchased_unit_code: ' ',
        reference_quantity: '1',
        reference_unit_code: 'gram'
      )
      unknown = described_class.new(
        purchased_quantity: '1',
        purchased_unit_code: '束',
        reference_quantity: '1',
        reference_unit_code: 'gram'
      )

      aggregate_failures do
        expect(blank.purchased_unit).to have_attributes(status: :blank, code: nil)
        expect(unknown.purchased_unit).to have_attributes(status: :unknown, code: nil, raw: '束')
        expect(blank.purchased_unit.code).not_to eq('each')
        expect(unknown.purchased_unit.code).not_to eq('each')
        expect(blank).not_to be_reference_basis_complete
        expect(unknown).not_to be_reference_basis_complete
        expect { blank.validate_reference_formula! }
          .to raise_error(described_class::InvalidFormulaSourceError)
        expect { unknown.validate_reference_formula! }
          .to raise_error(described_class::InvalidFormulaSourceError)
      end
    end

    it 'manual count formulaではknown countable unitだけを許可する' do
      known = described_class.new(purchased_quantity: '2', purchased_unit_code: 'box')
      measurement = described_class.new(purchased_quantity: '2', purchased_unit_code: 'gram')
      unknown = described_class.new(purchased_quantity: '2', purchased_unit_code: '束')

      aggregate_failures do
        expect(known.validate_count_formula!).to equal(known)
        expect { measurement.validate_count_formula! }
          .to raise_error(described_class::InvalidFormulaSourceError)
        expect { unknown.validate_count_formula! }
          .to raise_error(described_class::InvalidFormulaSourceError)
      end
    end

    it 'reference formulaでは同一conversion groupだけを許可する' do
      compatible = described_class.new(
        purchased_quantity: '1.5',
        purchased_unit_code: 'liter',
        reference_quantity: '500',
        reference_unit_code: 'milliliter'
      )
      cross_dimension = described_class.new(
        purchased_quantity: '1.5',
        purchased_unit_code: 'liter',
        reference_quantity: '500',
        reference_unit_code: 'gram'
      )
      countable_cross_code = described_class.new(
        purchased_quantity: '2',
        purchased_unit_code: 'box',
        reference_quantity: '1',
        reference_unit_code: 'each'
      )

      aggregate_failures do
        expect(compatible).to be_reference_basis_complete
        expect(cross_dimension).not_to be_reference_basis_complete
        expect(countable_cross_code).not_to be_reference_basis_complete
        expect { cross_dimension.validate_reference_formula! }
          .to raise_error(described_class::InvalidFormulaSourceError)
        expect { countable_cross_code.validate_reference_formula! }
          .to raise_error(described_class::InvalidFormulaSourceError)
      end
    end

    it 'quantityをbinary Floatへ変換せずexact positive valueとして検証する' do
      valid_decimal = described_class.new(
        purchased_quantity: BigDecimal('1.5'),
        purchased_unit_code: 'liter',
        reference_quantity: Rational(500),
        reference_unit_code: 'milliliter'
      )
      invalid_values = [
        'bogus', '0', '-1', '0.0001', 1.5,
        BigDecimal('NaN'), BigDecimal('Infinity'), BigDecimal('-Infinity')
      ]

      aggregate_failures do
        expect(valid_decimal).to be_reference_basis_complete

        invalid_values.each do |value|
          invalid_purchased = described_class.new(
            purchased_quantity: value,
            purchased_unit_code: 'liter',
            reference_quantity: '500',
            reference_unit_code: 'milliliter'
          )
          invalid_reference = described_class.new(
            purchased_quantity: '1.5',
            purchased_unit_code: 'liter',
            reference_quantity: value,
            reference_unit_code: 'milliliter'
          )

          [ invalid_purchased, invalid_reference ].each do |semantics|
            expect(semantics).not_to be_reference_basis_complete, value.inspect
            expect { semantics.validate_reference_formula! }
              .to raise_error(described_class::InvalidFormulaSourceError), value.inspect
          end
        end
      end
    end

    it 'unitごとのinput granularityに合うquantityだけをformula sourceにする' do
      valid_count = described_class.new(purchased_quantity: '2.0', purchased_unit_code: 'box')
      fractional_count = described_class.new(purchased_quantity: '1.5', purchased_unit_code: 'box')
      valid_measurement = described_class.new(
        purchased_quantity: '0.001',
        purchased_unit_code: 'gram',
        reference_quantity: '0.001',
        reference_unit_code: 'gram'
      )
      excessive_precision = described_class.new(
        purchased_quantity: '0.0009',
        purchased_unit_code: 'gram',
        reference_quantity: '0.001',
        reference_unit_code: 'gram'
      )

      aggregate_failures do
        expect(valid_count.validate_count_formula!).to equal(valid_count)
        expect { fractional_count.validate_count_formula! }
          .to raise_error(described_class::InvalidFormulaSourceError)
        expect(valid_measurement).to be_reference_basis_complete
        expect(excessive_precision).not_to be_reference_basis_complete
      end
    end
  end
end
