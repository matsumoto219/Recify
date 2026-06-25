# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
security_exact_key_filter = /\A(?:credential|raw[_-]?id|attestation[_-]?object|client[_-]?data[_-]?json|authenticator[_-]?data|public[_-]?key|credential[_-]?id|challenge|signature|user[_-]?handle|totp|otp[_-]?attempt|totp[_-]?code|totp[_-]?secret|encrypted[_-]?totp[_-]?secret|recovery[_-]?codes?|backup[_-]?codes?|provisioning[_-]?uri|otpauth|code|code[_-]?digest|session[_-]?uid(?:[_-]?digest)?|raw[_-]?response|two[_-]?factor|second[_-]?factor|one[_-]?time[_-]?password|cf[_-]?turnstile[_-]?response|g[_-]?recaptcha[_-]?response|authorization|endpoint|signed[_-]?id|blob[_-]?key|storage[_-]?key|checksum|content[_-]?md5)\z/i

Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  security_exact_key_filter
]
