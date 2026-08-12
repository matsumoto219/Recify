require 'rails_helper'

RSpec.describe Amounts::ItemPricingSource do
  let(:countable_quantity) do
    Amounts::ItemQuantitySemantics.new(
      purchased_quantity: '2',
      purchased_unit_code: 'box'
    )
  end

  let(:reference_quantity) do
    Amounts::ItemQuantitySemantics.new(
      purchased_quantity: '1.5',
      purchased_unit_code: 'liter',
      reference_quantity: '500',
      reference_unit_code: 'milliliter'
    )
  end

  describe 'authority kind' do
    it '承認済みの3 authority kindだけを許可する' do
      expect(described_class::AUTHORITY_KINDS).to eq(
        %i[count_unit_price explicit_line_total reference_quantity_price]
      )
    end

    it 'context authority/state rule metadataをdeep immutableにする' do
      aggregate_failures do
        expect(described_class::SOURCE_RULES).to be_frozen
        expect(described_class::SOURCE_RULES.values).to all(be_frozen)
        expect(described_class::SOURCE_RULES.values.flat_map(&:values)).to all(be_frozen)
        expect(described_class::SOURCE_RULES.values.flat_map(&:values).map(&:validation_states)).to all(be_frozen)
        expect(
          described_class::SOURCE_RULES.values.flat_map(&:values).map(&:reference_price_tax_inclusions)
        ).to all(be_frozen)
      end
    end

    it 'unknown authority kindを拒否する' do
      expect do
        described_class.new(
          authority_kind: :inferred_formula,
          context: :manual,
          source_evidence: :confirmed_reference_quantity_price,
          quantity_semantics: reference_quantity
        )
      end.to raise_error(described_class::InvalidContractError)
    end

    it 'unit kindやhidden line totalからauthority kindを推論する入力を受け付けない' do
      expect do
        described_class.new(
          context: :manual,
          source_evidence: :confirmed_reference_quantity_price,
          unit_kind: :decimal,
          hidden_line_total: 180
        )
      end.to raise_error(ArgumentError)
    end

    it 'context/evidence/stateはStringかSymbolだけを受け付ける' do
      symbol_like = Object.new
      symbol_like.define_singleton_method(:to_sym) { :manual }

      expect do
        described_class.new(
          authority_kind: :explicit_line_total,
          context: symbol_like,
          source_evidence: :entered_explicit_total,
          explicit_line_total: 360
        )
      end.to raise_error(described_class::InvalidContractError)
    end
  end

  describe 'approved context authority' do
    it 'strongly attributed analysis printed totalだけをexplicit authorityにする' do
      source = described_class.analysis_printed(explicit_line_total: 1_136)

      aggregate_failures do
        expect(source).to have_attributes(
          authority_kind: :explicit_line_total,
          context: :analysis,
          source_evidence: :strongly_attributed_printed_total,
          validation_state: :valid,
          explicit_line_total: 1_136
        )
        expect(source).to be_explicit
        expect(source).not_to be_formula
      end
    end

    it 'weakまたは不明なanalysis evidenceをexplicit authorityにしない' do
      expect do
        described_class.new(
          authority_kind: :explicit_line_total,
          context: :analysis,
          source_evidence: :unattributed_line_total,
          explicit_line_total: 1_136
        )
      end.to raise_error(described_class::InvalidContractError)
    end

    it 'manual explicit totalをentered total authorityとして保持する' do
      source = described_class.manual_explicit(explicit_line_total: 360)

      expect(source).to have_attributes(
        authority_kind: :explicit_line_total,
        context: :manual,
        source_evidence: :entered_explicit_total,
        explicit_line_total: 360
      )
    end

    it 'manual explicitでnilやmissing stateを明示金額へ変換しない' do
      aggregate_failures do
        expect { described_class.manual_explicit(explicit_line_total: nil) }
          .to raise_error(described_class::InvalidContractError)
        expect do
          described_class.manual_explicit(explicit_line_total: 360, validation_state: :missing)
        end.to raise_error(described_class::InvalidContractError)
      end
    end

    it 'explicit line totalは現行契約の非負Integer yenだけを受け付ける' do
      [ -1, '360', BigDecimal('360.0'), [], {} ].each do |value|
        expect do
          described_class.manual_explicit(explicit_line_total: value)
        end.to raise_error(described_class::InvalidContractError), value.inspect
      end
    end

    it 'existing countableを明示entrypointから現行formula authorityにする' do
      analysis = described_class.existing_countable(
        context: :analysis,
        quantity_semantics: countable_quantity
      )
      manual = described_class.existing_countable(
        context: :manual,
        quantity_semantics: countable_quantity
      )
      persisted_without_source_metadata = described_class.existing_countable(
        context: :persisted_without_source_metadata,
        quantity_semantics: countable_quantity
      )

      aggregate_failures do
        expect(analysis).to have_attributes(
          authority_kind: :count_unit_price,
          context: :analysis,
          source_evidence: :existing_countable_formula
        )
        expect(manual).to have_attributes(
          authority_kind: :count_unit_price,
          context: :manual,
          source_evidence: :existing_countable_formula
        )
        expect(persisted_without_source_metadata).to have_attributes(
          authority_kind: :count_unit_price,
          context: :persisted_without_source_metadata,
          source_evidence: :existing_countable_formula
        )
        expect(analysis).to be_formula
        expect(manual).to be_formula
        expect(persisted_without_source_metadata).to be_formula
      end
    end

    it 'manual reference formulaをconfirmed pricing basis authorityとして保持する' do
      source = described_class.manual_reference(
        quantity_semantics: reference_quantity,
        reference_price_tax_inclusion: :gross
      )

      expect(source).to have_attributes(
        authority_kind: :reference_quantity_price,
        context: :manual,
        source_evidence: :confirmed_reference_quantity_price,
        quantity_semantics: reference_quantity,
        reference_price_tax_inclusion: :gross
      )
      expect(source).to be_formula
    end

    it 'edit_save explicit/referenceをmanualと分離したcontextで保持する' do
      explicit = described_class.edit_save_explicit(explicit_line_total: 360)
      references = %i[gross net].map do |tax_inclusion|
        described_class.edit_save_reference(
          quantity_semantics: reference_quantity,
          reference_price_tax_inclusion: tax_inclusion
        )
      end
      countable = described_class.existing_countable(
        context: :edit_save,
        quantity_semantics: countable_quantity
      )

      aggregate_failures do
        expect(explicit).to have_attributes(
          authority_kind: :explicit_line_total,
          context: :edit_save,
          source_evidence: :entered_explicit_total
        )
        references.zip(%i[gross net]).each do |reference, tax_inclusion|
          expect(reference).to have_attributes(
            authority_kind: :reference_quantity_price,
            context: :edit_save,
            source_evidence: :confirmed_reference_quantity_price,
            reference_price_tax_inclusion: tax_inclusion
          )
        end
        expect(countable).to have_attributes(
          authority_kind: :count_unit_price,
          context: :edit_save,
          source_evidence: :existing_countable_formula
        )
      end
    end

    it 'manual reference formulaはgrossだけを許可しnet/unknown/欠損から推測しない' do
      aggregate_failures do
        expect do
          described_class.manual_reference(
            quantity_semantics: reference_quantity,
            reference_price_tax_inclusion: :net
          )
        end.to raise_error(described_class::InvalidContractError)
        expect do
          described_class.new(
            authority_kind: :reference_quantity_price,
            context: :manual,
            source_evidence: :confirmed_reference_quantity_price,
            quantity_semantics: reference_quantity,
            reference_price_tax_inclusion: :net
          )
        end.to raise_error(described_class::InvalidContractError)
        expect do
          described_class.manual_reference(
            quantity_semantics: reference_quantity,
            reference_price_tax_inclusion: nil
          )
        end.to raise_error(described_class::InvalidContractError)
        expect do
          described_class.manual_reference(
            quantity_semantics: reference_quantity,
            reference_price_tax_inclusion: :unknown
          )
        end.to raise_error(described_class::InvalidContractError)
      end
    end

    it 'count/explicit authorityへreference priceのtax inclusionを混ぜない' do
      aggregate_failures do
        expect do
          described_class.new(
            authority_kind: :count_unit_price,
            context: :manual,
            source_evidence: :existing_countable_formula,
            quantity_semantics: countable_quantity,
            reference_price_tax_inclusion: :gross
          )
        end.to raise_error(described_class::InvalidContractError)
        expect do
          described_class.new(
            authority_kind: :explicit_line_total,
            context: :manual,
            source_evidence: :entered_explicit_total,
            explicit_line_total: 360,
            reference_price_tax_inclusion: :net
          )
        end.to raise_error(described_class::InvalidContractError)
      end
    end
  end

  describe 'authority and validation state separation' do
    it 'ambiguous/unsupportedをauthority kindに含めない' do
      aggregate_failures do
        expect(described_class::AUTHORITY_KINDS).not_to include(:ambiguous, :unsupported)
        expect(described_class::VALIDATION_STATES).to include(:ambiguous, :unsupported)
      end
    end

    it 'ambiguous/unsupported stateをformula authorityへ昇格させない' do
      %i[ambiguous unsupported].each do |state|
        expect do
          described_class.new(
            authority_kind: :reference_quantity_price,
            context: :manual,
            source_evidence: :confirmed_reference_quantity_price,
            validation_state: state,
            quantity_semantics: reference_quantity,
            reference_price_tax_inclusion: :gross
          )
        end.to raise_error(described_class::InvalidContractError), state.to_s
      end
    end

    it 'unsupported formula evidenceがあってもstrong printed total authorityを維持できる' do
      source = described_class.analysis_printed(
        explicit_line_total: 1_136,
        validation_state: :unsupported
      )

      aggregate_failures do
        expect(source.authority_kind).to eq(:explicit_line_total)
        expect(source.validation_state).to eq(:unsupported)
        expect(source.explicit_line_total).to eq(1_136)
      end
    end

    it 'analysis ambiguous/unsupported evidenceをauthorityなしのreview stateとして表現する' do
      unknown = Amounts::ItemQuantitySemantics.new(
        purchased_quantity: '1',
        purchased_unit_code: '束'
      )
      ambiguous = described_class.analysis_ambiguous
      unsupported = described_class.analysis_unsupported(quantity_semantics: unknown)

      aggregate_failures do
        expect(ambiguous).to have_attributes(
          authority_kind: nil,
          context: :analysis,
          source_evidence: :ambiguous_pricing_evidence,
          validation_state: :ambiguous,
          quantity_semantics: nil,
          reference_price_tax_inclusion: nil
        )
        expect(unsupported).to have_attributes(
          authority_kind: nil,
          context: :analysis,
          source_evidence: :unsupported_pricing_evidence,
          validation_state: :unsupported,
          quantity_semantics: unknown,
          reference_price_tax_inclusion: nil
        )
        expect(unsupported.quantity_semantics.purchased_unit).to have_attributes(
          status: :unknown,
          code: nil,
          raw: '束'
        )
        expect(ambiguous).not_to be_authoritative
        expect(unsupported).not_to be_authoritative
        expect(unsupported.quantity_semantics).to be_frozen
      end
    end

    it 'authorityなしのanalysis review evidenceへtax inclusionを混ぜない' do
      expect do
        described_class.new(
          authority_kind: nil,
          context: :analysis,
          source_evidence: :unsupported_pricing_evidence,
          validation_state: :unsupported,
          reference_price_tax_inclusion: :gross
        )
      end.to raise_error(described_class::InvalidContractError)
    end

    it 'no-authority state/evidence不一致とformula authorityへの昇格を拒否する' do
      invalid_contracts = [
        {
          authority_kind: nil,
          context: :analysis,
          source_evidence: :unsupported_pricing_evidence,
          validation_state: :ambiguous
        },
        {
          authority_kind: nil,
          context: :analysis,
          source_evidence: :unsupported_pricing_evidence,
          validation_state: :valid
        },
        {
          authority_kind: nil,
          context: :analysis,
          source_evidence: :ambiguous_pricing_evidence,
          validation_state: :missing
        },
        {
          authority_kind: :reference_quantity_price,
          context: :analysis,
          source_evidence: :unsupported_pricing_evidence,
          validation_state: :unsupported,
          quantity_semantics: reference_quantity,
          reference_price_tax_inclusion: :gross
        }
      ]

      invalid_contracts.each do |attributes|
        expect { described_class.new(**attributes) }
          .to raise_error(described_class::InvalidContractError), attributes.inspect
      end
    end

    it 'no-authority review stateへmutable hashを保持しない' do
      expect do
        described_class.new(
          authority_kind: nil,
          context: :analysis,
          source_evidence: :unsupported_pricing_evidence,
          validation_state: :unsupported,
          quantity_semantics: {}
        )
      end.to raise_error(described_class::InvalidContractError)
    end

    it 'formula authorityへexplicit/hidden totalを混ぜない' do
      expect do
        described_class.new(
          authority_kind: :reference_quantity_price,
          context: :manual,
          source_evidence: :confirmed_reference_quantity_price,
          explicit_line_total: 999,
          quantity_semantics: reference_quantity,
          reference_price_tax_inclusion: :gross
        )
      end.to raise_error(described_class::InvalidContractError)
    end

    it 'explicit authorityへquantity semanticsやmutable containerを保持しない' do
      expect do
        described_class.new(
          authority_kind: :explicit_line_total,
          context: :manual,
          source_evidence: :entered_explicit_total,
          explicit_line_total: 360,
          quantity_semantics: {}
        )
      end.to raise_error(described_class::InvalidContractError)
    end
  end

  describe '.measurement_without_source_metadata' do
    it 'positive explicit totalをそのままauthorityとして保持する' do
      source = described_class.measurement_without_source_metadata(explicit_line_total: 1_136)

      expect(source).to have_attributes(
        authority_kind: :explicit_line_total,
        validation_state: :valid,
        explicit_line_total: 1_136
      )
    end

    it 'zero explicit totalをmissingやformulaへ変換しない' do
      source = described_class.measurement_without_source_metadata(explicit_line_total: 0)

      aggregate_failures do
        expect(source.authority_kind).to eq(:explicit_line_total)
        expect(source.validation_state).to eq(:valid)
        expect(source.explicit_line_total).to eq(0)
        expect(source).to be_explicit
      end
    end

    it 'nil totalをmissingとして保持し0やformulaを推測しない' do
      source = described_class.measurement_without_source_metadata(explicit_line_total: nil)

      aggregate_failures do
        expect(source.authority_kind).to be_nil
        expect(source.validation_state).to eq(:missing)
        expect(source.explicit_line_total).to be_nil
        expect(source).not_to be_authoritative
        expect(source).not_to be_formula
      end
    end
  end

  describe 'invalid reference pricing source' do
    it 'package-only情報からreference authorityを構築しない' do
      package_only = Amounts::ItemQuantitySemantics.new(
        package_content: :opaque_package_evidence
      )

      expect do
        described_class.manual_reference(
          quantity_semantics: package_only,
          reference_price_tax_inclusion: :gross
        )
      end.to raise_error(Amounts::ItemQuantitySemantics::InvalidFormulaSourceError)
    end

    it 'unknown unitをeachへfallbackしてreference authorityを構築しない' do
      unknown = Amounts::ItemQuantitySemantics.new(
        purchased_quantity: '1',
        purchased_unit_code: '束',
        reference_quantity: '1',
        reference_unit_code: 'gram'
      )

      expect do
        described_class.manual_reference(
          quantity_semantics: unknown,
          reference_price_tax_inclusion: :gross
        )
      end.to raise_error(Amounts::ItemQuantitySemantics::InvalidFormulaSourceError)
      expect(unknown.purchased_unit).to have_attributes(status: :unknown, code: nil)
    end
    it 'invalid・zero・negative・granularity違反quantityをvalid authorityにしない' do
      [ 'bogus', '0', '-1', '0.0001', 1.5 ].each do |value|
        semantics = Amounts::ItemQuantitySemantics.new(
          purchased_quantity: value,
          purchased_unit_code: 'liter',
          reference_quantity: '500',
          reference_unit_code: 'milliliter'
        )

        expect do
          described_class.manual_reference(
            quantity_semantics: semantics,
            reference_price_tax_inclusion: :gross
          )
        end.to raise_error(Amounts::ItemQuantitySemantics::InvalidFormulaSourceError), value.inspect
      end
    end
  end

  it '入力hashを変更せずimmutable sourceを返す' do
    attributes = {
      authority_kind: :reference_quantity_price,
      context: :manual,
      source_evidence: :confirmed_reference_quantity_price,
      quantity_semantics: reference_quantity,
      reference_price_tax_inclusion: +'gross'
    }
    original = attributes.dup

    source = described_class.new(**attributes)

    aggregate_failures do
      expect(attributes).to eq(original)
      expect(source).to be_frozen
      expect(source.quantity_semantics).to equal(reference_quantity)
      expect(source.reference_price_tax_inclusion).to eq(:gross)
      expect(attributes[:reference_price_tax_inclusion]).to eq('gross')
      expect(attributes[:reference_price_tax_inclusion]).not_to be_frozen
    end
  end
end
