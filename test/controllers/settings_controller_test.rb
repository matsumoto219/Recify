require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_with_current_legal_acceptance users(:one)
  end

  test "should get index" do
    get settings_url
    assert_response :success
  end

  test "should get account" do
    get settings_account_url
    assert_response :success
  end

  test "should get security" do
    get settings_security_url
    assert_response :success
  end
end
