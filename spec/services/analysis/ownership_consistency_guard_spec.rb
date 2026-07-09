require "rails_helper"

RSpec.describe Analysis::OwnershipConsistencyGuard do
  def contract(**overrides)
    {
      schema_version: 1,
      duplicate_source_owner_count: 0,
      payment_source_purchase_adjustment_count: 0,
      tax_detail_source_effect_count: 0,
      unknown_purchase_tax_allocation_count: 0,
      adjustment_review_required_count: 0
    }.merge(overrides)
  end

  it "clean contractではreview stateを増やさない" do
    params = {
      ownership_contract: contract,
      review_reasons: []
    }

    result = described_class.call(params: params)

    aggregate_failures do
      expect(result[:review_reasons]).to eq([])
      expect(result).not_to have_key(:status)
      expect(params[:review_reasons]).to eq([])
    end
  end

  it "source owner conflictをsemantic再判定せずreview reasonへ反映する" do
    %i[
      duplicate_source_owner_count
      payment_source_purchase_adjustment_count
      tax_detail_source_effect_count
    ].each do |key|
      result = described_class.call(
        params: {
          ownership_contract: contract(key => 1),
          review_reasons: []
        }
      )

      expect(result[:review_reasons]).to include("adjustment_uncertain")
    end
  end

  it "unknown purchase tax allocationをreview-requiredとして保持する" do
    result = described_class.call(
      params: {
        ownership_contract: contract(unknown_purchase_tax_allocation_count: 1),
        review_reasons: []
      }
    )

    expect(result[:review_reasons]).to eq([ "purchase_adjustment_tax_allocation_uncertain" ])
  end

  it "安全な単一税率でreview対象外のunknown tax allocationは過検知しない" do
    ownership_result = Analysis::OwnershipResult.new(
      facts: [
        Analysis::OwnershipFact.new(
          origin: :adjustment,
          fact_type: :purchase_adjustment,
          tax_rate_source: :unknown,
          action: :persist,
          review_reasons: [],
          source_refs: [],
          attributes: {}
        )
      ]
    )

    expect(described_class.contract_for(ownership_result)).to include(
      unknown_purchase_tax_allocation_count: 0
    )
  end

  it "resolverが危険と判定したunknown tax allocationをcontractへ残す" do
    ownership_result = Analysis::OwnershipResult.new(
      facts: [
        Analysis::OwnershipFact.new(
          origin: :adjustment,
          fact_type: :purchase_adjustment,
          tax_rate_source: :unknown,
          action: :persist,
          review_reasons: [ "purchase_adjustment_tax_allocation_uncertain" ],
          source_refs: [],
          attributes: {}
        )
      ]
    )

    expect(described_class.contract_for(ownership_result)).to include(
      unknown_purchase_tax_allocation_count: 1
    )
  end

  it "resolver contractがadjustment review解消を保証する場合だけstale reasonを解消可能と返す" do
    aggregate_failures do
      expect(
        described_class.review_reason_resolved?(
          params: { ownership_contract: contract },
          reason: "adjustment_uncertain"
        )
      ).to be(true)
      expect(
        described_class.review_reason_resolved?(
          params: { ownership_contract: contract(adjustment_review_required_count: 1) },
          reason: "adjustment_uncertain"
        )
      ).to be(false)
      expect(
        described_class.review_reason_resolved?(
          params: {},
          reason: "adjustment_uncertain"
        )
      ).to be(false)
    end
  end
end
