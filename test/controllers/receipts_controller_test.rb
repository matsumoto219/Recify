require "test_helper"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    user = FactoryBot.create(:user)
    @receipt = FactoryBot.create(
      :receipt,
      user: user,
      total_amount: 110,
      subtotal_amount: 100,
      tax_amount: 10,
      tax_rate: BigDecimal("0.1"),
      memo: "表示確認用メモ",
      receipt_items_attributes: [ {
        confirmed_name: "テスト商品",
        category: "daily_goods",
        price: 110,
        quantity: 1,
        line_total: 110,
        tax_rate: BigDecimal("0.1"),
        needs_review: false,
        position_index: 0
      } ],
      receipt_payments_attributes: [ { method: "cash", amount: 110 } ],
      receipt_tax_details_attributes: [ { rate: BigDecimal("0.1"), amount: 10, net_amount: 100 } ]
    )
    sign_in_with_current_legal_acceptance user
  end

  test "should get index" do
    get receipts_url
    assert_response :success
  end

  test "should get show" do
    get receipt_url(@receipt)
    assert_response :success
    assert_select "p[title='テスト商品']", text: "テスト商品"
    assert_select "div", text: "表示確認用メモ"
  end

  test "should get new" do
    get new_receipt_url
    assert_response :success
  end

  test "should get edit" do
    get edit_receipt_url(@receipt)
    assert_response :success
    assert_select "input[name='receipt[receipt_items_attributes][0][confirmed_name]'][value='テスト商品']"
    assert_select "input[name='receipt[receipt_payments_attributes][0][amount]'][value='110']"
  end
end
