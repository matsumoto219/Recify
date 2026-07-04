require "test_helper"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_with_current_legal_acceptance users(:one)
  end

  test "should get index" do
    get receipts_url
    assert_response :success
  end

  test "should get show" do
    get receipt_url(receipts(:one))
    assert_response :success
  end

  test "should get new" do
    get new_receipt_url
    assert_response :success
  end

  test "should get edit" do
    get edit_receipt_url(receipts(:one))
    assert_response :success
  end
end
