# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :credential, :rawId, :raw_id, :attestationObject, :attestation_object, :clientDataJSON, :client_data_json,
  :authenticatorData, :authenticator_data, :publicKey, :public_key, :credential_id, :challenge, :signature,
  :userHandle, :user_handle, :totp, :otp_attempt, :totp_code, :totp_secret, :encrypted_totp_secret,
  :recovery_code, :recovery_codes, :backup_code, :backup_codes, :provisioning_uri, :otpauth,
  :two_factor, :second_factor, :one_time_password
]
