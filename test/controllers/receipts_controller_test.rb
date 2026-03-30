require "test_helper"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get receipts_index_url
    assert_response :success
  end

  test "should get show" do
    get receipts_show_url
    assert_response :success
  end

  test "should get new" do
    get receipts_new_url
    assert_response :success
  end

  test "should get edit" do
    get receipts_edit_url
    assert_response :success
  end
end
