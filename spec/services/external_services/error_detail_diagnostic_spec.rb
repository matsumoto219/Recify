require 'spec_helper'
require 'active_support/all'
require 'json'
require_relative '../../../app/services/external_services'
require_relative '../../../app/services/external_services/error_text_sanitizer'
require_relative '../../../app/services/external_services/error_diagnostic'
require_relative '../../../app/services/external_services/error_detail'

RSpec.describe ExternalServices::ErrorDetail do
  describe '.build' do
    it 'Azureの内側の原因とdetailsを元の順序で残す' do
      detail = described_class.build(
        http_status: 400,
        body: {
          error: {
            code: 'InvalidRequest',
            message: 'Invalid request.',
            innererror: {
              code: 'InvalidContentLength',
              message: 'The input image is too large.',
              details: [
                { code: 'InvalidParameter', target: 'document', message: 'Document exceeds the file limit.' }
              ]
            }
          }
        }
      )

      expect(detail).to include(provider_error_code: 'InvalidRequest', provider_message_safe: 'Invalid request.')
      expect(detail[:diagnostic]).to eq(
        schema_version: 'external_service_error_diagnostic_v1',
        nodes: [
          { path: 'error', code: 'InvalidRequest', message_safe: 'Invalid request.' },
          { path: 'error.innererror', code: 'InvalidContentLength', message_safe: 'The input image is too large.' },
          {
            path: 'error.innererror.details[0]',
            code: 'InvalidParameter',
            target: 'document',
            message_safe: 'Document exceeds the file limit.'
          }
        ],
        omissions: []
      )
    end

    it 'OpenAIのparamとtypeを保存し入力値やdebug objectは取り込まない' do
      detail = described_class.build(
        body: {
          error: {
            code: 'invalid_value',
            type: 'invalid_request_error',
            param: 'text.format.schema.properties.items',
            message: 'Invalid schema.',
            value: 'private input',
            debug: { prompt: 'private prompt', authorization: 'private credential' }
          },
          output: [ { content: 'private response' } ]
        }
      )

      expect(detail.dig(:diagnostic, :nodes)).to eq([
        {
          path: 'error',
          code: 'invalid_value',
          type: 'invalid_request_error',
          param: 'text.format.schema.properties.items',
          message_safe: 'Invalid schema.'
        }
      ])
      expect(JSON.generate(detail)).not_to match(/private|authorization|prompt|output/)
    end

    it '配列indexを含むparameter pathを安全な構造情報として保持する' do
      detail = described_class.build(body: { error: { code: 'invalid_value', param: 'messages[0].content[1].type' } })

      expect(detail.dig(:diagnostic, :nodes, 0, :param)).to eq('messages[0].content[1].type')
    end

    it '構造parameter内の機密識別子もfallbackで再許可しない' do
      detail = described_class.build(body: { error: { code: 'invalid_value', param: "param[0].#{'a' * 32}" } })

      expect(detail.dig(:diagnostic, :nodes, 0)).not_to have_key(:param)
      expect(detail.dig(:diagnostic, :omissions)).to include(path: 'error.param', reason: 'redacted')
      expect(JSON.generate(detail[:diagnostic])).not_to include('a' * 32)
    end

    it 'camel caseのinnerErrorも構造pathを区別して保存する' do
      detail = described_class.build(body: { error: { innerError: { code: 'InvalidImage' } } })

      expect(detail.dig(:diagnostic, :nodes)).to include(path: 'error.innerError', code: 'InvalidImage')
    end

    it '未登録の安全な原因codeとmessageも具体的な内容を維持する' do
      detail = described_class.build(
        body: {
          error: {
            code: 'FutureProviderFailure',
            innererror: { code: 'FutureDocumentPolicy', type: 'new_policy_error', message: 'A new document rule was violated.' }
          }
        }
      )

      expect(detail.dig(:diagnostic, :nodes, 1)).to include(
        code: 'FutureDocumentPolicy',
        type: 'new_policy_error',
        message_safe: 'A new document rule was violated.'
      )
    end

    it '未知error fieldはraw key/valueを保存せず未取得の情報があることを明示する' do
      detail = described_class.build(
        body: {
          error: { code: 'FutureFailure', explanation: { private_field: 'private value' } },
          usage: { private_metadata: 'private metadata' }
        }
      )

      expect(detail.dig(:diagnostic, :nodes)).to eq([ { path: 'error', code: 'FutureFailure' } ])
      expect(detail.dig(:diagnostic, :omissions)).to eq([ { path: 'error', reason: 'unsupported_fields' } ])
      expect(JSON.generate(detail)).not_to match(/explanation|private|usage/)
    end

    it 'incomplete_detailsの未知の安全なreasonをAPIの具体的な値として保持する' do
      detail = described_class.build(
        body: { error: nil, incomplete_details: { reason: 'future_completion_limit' }, status: 'incomplete' },
        local_issue: 'incomplete'
      )

      expect(detail.dig(:diagnostic, :nodes)).to eq([
        { path: 'incomplete_details', reason: 'future_completion_limit' }
      ])
      expect(detail.dig(:diagnostic, :omissions)).to eq([])
      expect(described_class.build(**JSON.parse(JSON.generate(detail)).deep_symbolize_keys)).to eq(detail)
    end

    it '500bytesより長い安全な診断messageを切断せず4096bytesまで保持する' do
      message = "Invalid schema. #{'The required field is missing. ' * 30}"
      detail = described_class.build(body: { error: { message: message } })

      expect(detail.dig(:diagnostic, :nodes, 0, :message_safe)).to eq(message.strip)
      expect(detail.dig(:diagnostic, :omissions)).to eq([])
    end

    it '4096bytesを超えたmessageは理由を残しcodeを維持する' do
      detail = described_class.build(body: { error: { code: 'InvalidRequest', message: 'あ' * 1_366 } })

      expect(detail.dig(:diagnostic, :nodes)).to eq([ { path: 'error', code: 'InvalidRequest' } ])
      expect(detail.dig(:diagnostic, :omissions)).to include(path: 'error.message', reason: 'byte_limit')
      expect(JSON.generate(detail[:diagnostic])).not_to include('あ')
    end

    it '内側のmessageにある機密情報だけを除去して原因を維持する' do
      detail = described_class.build(
        body: {
          error: {
            innererror: {
              code: 'InvalidParameter',
              message: 'Invalid input for person@example.test; api_key=private-credential; prompt=private input'
            }
          }
        }
      )

      message = detail.dig(:diagnostic, :nodes, 1, :message_safe)
      expect(message).to include('Invalid input', '[FILTERED]')
      expect(message).not_to match(/person@|private-credential|private input/)
      expect(detail.dig(:diagnostic, :omissions)).to include(path: 'error.innererror.message', reason: 'redacted')
    end

    it 'messageに反射された入力値を除去して独立した原因とparameterを維持する' do
      detail = described_class.build(
        body: {
          error: {
            code: 'invalid_value',
            param: 'input',
            message: "Unsupported input: 'private receipt text'; expected a document."
          }
        }
      )

      expect(detail.dig(:diagnostic, :nodes, 0)).to include(
        code: 'invalid_value',
        param: 'input',
        message_safe: 'Unsupported [FILTERED]; expected a document.'
      )
      expect(JSON.generate(detail)).not_to include('private receipt text')
    end

    it 'inline data URIを除去して画像本体やbase64文字列を保存しない' do
      detail = described_class.build(
        body: { error: { code: 'InvalidImage', message: 'Invalid image data:image/jpeg;base64,cHJpdmF0ZSBpbWFnZQ==.' } }
      )

      expect(detail.dig(:diagnostic, :nodes, 0, :message_safe)).to include('Invalid image', '[FILTERED]')
      expect(detail.dig(:diagnostic, :omissions)).to include(path: 'error.message', reason: 'redacted')
      expect(JSON.generate(detail)).not_to match(/data:image|cHJpdmF0ZSBpbWFnZQ/)
    end

    it '不正型や機密を含むfieldは値を保存せずfieldと理由だけを残す' do
      detail = described_class.build(
        body: {
          error: {
            code: [ 'private input' ],
            type: 'invalid_request_error',
            param: 'person@example.test',
            message: { secret: 'private value' }
          }
        }
      )

      expect(detail.dig(:diagnostic, :nodes)).to eq([ { path: 'error', type: 'invalid_request_error' } ])
      expect(detail.dig(:diagnostic, :omissions)).to contain_exactly(
        { path: 'error.code', reason: 'invalid_type' },
        { path: 'error.param', reason: 'redacted' },
        { path: 'error.message', reason: 'invalid_type' }
      )
      expect(JSON.generate(detail)).not_to match(/person@|private input|private value/)
    end

    it '大きなbodyを解析せず欠落理由を保存する' do
      detail = described_class.build(http_status: 400, body: 'x' * 65_537)

      expect(detail[:http_status]).to eq(400)
      expect(detail.dig(:diagnostic, :nodes)).to eq([])
      expect(detail.dig(:diagnostic, :omissions)).to eq([ { path: 'body', reason: 'byte_limit' } ])
    end

    it 'JSON以外のbodyはraw本文を保存せず取得できない理由を残す' do
      detail = described_class.build(body: '<html>private provider response</html>')

      expect(detail.dig(:diagnostic, :nodes)).to eq([])
      expect(detail.dig(:diagnostic, :omissions)).to eq([ { path: 'body', reason: 'invalid_json' } ])
      expect(JSON.generate(detail)).not_to include('private provider response')
    end

    it '深い原因を無限に辿らず取得済みcodeと省略位置を残す' do
      body = { error: { code: 'Root' } }
      node = body[:error]
      6.times do |index|
        node[:innererror] = { code: "Nested#{index}" }
        node = node[:innererror]
      end
      detail = described_class.build(body: body)

      expect(detail.dig(:diagnostic, :nodes).size).to eq(5)
      expect(detail.dig(:diagnostic, :omissions)).to include(
        path: "error#{'.innererror' * 5}",
        reason: 'depth_limit'
      )
    end

    it 'details数の超過は最大16nodeで打ち切り件数上限を明示する' do
      detail = described_class.build(
        body: { error: { code: 'Root', details: Array.new(100) { |index| { code: "Detail#{index}" } } } }
      )

      expect(detail.dig(:diagnostic, :nodes).size).to eq(16)
      expect(detail.dig(:diagnostic, :nodes).last[:code]).to eq('Detail14')
      expect(detail.dig(:diagnostic, :omissions)).to include(path: 'error.details', reason: 'node_limit')
    end

    it '循環したHashはdepth上限で止まりraw objectを保持しない' do
      error = { code: 'Circular' }
      error[:innererror] = error
      detail = described_class.build(body: { error: error })

      expect(detail.dig(:diagnostic, :omissions)).to include(
        path: "error#{'.innererror' * 5}",
        reason: 'depth_limit'
      )
      expect { JSON.generate(detail) }.not_to raise_error
    end

    it 'JSON保存後の再検証でdiagnosticの意味や秘匿化理由が変わらない' do
      first = described_class.build(
        body: {
          error: { code: 'InvalidRequest', innererror: { code: 'InvalidParameter', message: 'Invalid person@example.test' } }
        }
      )
      stored = JSON.parse(JSON.generate(first)).deep_symbolize_keys
      second = described_class.build(**stored)

      expect(first[:diagnostic]).to be_present
      expect(second).to eq(first)
    end

    it '保存済みdiagnosticのunknown versionをraw表示しない' do
      detail = described_class.build(
        diagnostic: {
          schema_version: 'unknown',
          nodes: [ { path: 'error', message_safe: 'private data' } ],
          omissions: []
        }
      )

      expect(detail.dig(:diagnostic, :nodes)).to eq([])
      expect(detail.dig(:diagnostic, :omissions)).to eq([ { path: 'diagnostic', reason: 'unknown_version' } ])
      expect(JSON.generate(detail)).not_to include('private data')
    end

    it '保存済みdiagnosticも再sanitizeし未知fieldや不正pathを表示しない' do
      detail = described_class.build(
        diagnostic: {
          schema_version: 'external_service_error_diagnostic_v1',
          nodes: [
            { path: 'error', code: 'InvalidRequest', message_safe: 'Failure person@example.test', debug: 'private data' },
            { path: 'private-path', code: 'InvalidValue' }
          ],
          omissions: [ { path: 'error.message', reason: 'arbitrary private reason' } ]
        }
      )

      expect(detail.dig(:diagnostic, :nodes)).to eq([
        { path: 'error', code: 'InvalidRequest', message_safe: 'Failure [FILTERED]' }
      ])
      expect(JSON.generate(detail)).not_to match(/person@|private/)
      expect(detail.dig(:diagnostic, :omissions)).to include(path: 'diagnostic', reason: 'invalid_structure')
    end

    it '多数の省略理由も上限内に保ち省略自体の超過を明示する' do
      diagnostic = {
        schema_version: 'external_service_error_diagnostic_v1',
        nodes: [],
        omissions: Array.new(200) { { path: 'error.message', reason: 'redacted' } }
      }
      detail = described_class.build(diagnostic: diagnostic)

      expect(detail.dig(:diagnostic, :omissions)).to contain_exactly(
        { path: 'error.message', reason: 'redacted' },
        { path: 'diagnostic', reason: 'omission_limit' }
      )
    end

    it '最大nodeのJSON escape後の全体容量超過を明示しraw payloadを保持しない' do
      nodes = Array.new(16) do |index|
        { path: "error.details[#{index}]", code: 'InvalidRequest', message_safe: '"' * 4_096 }
      end
      detail = described_class.build(
        diagnostic: { schema_version: 'external_service_error_diagnostic_v1', nodes: nodes, omissions: [] }
      )

      expect(detail[:diagnostic]).to eq(
        schema_version: 'external_service_error_diagnostic_v1',
        nodes: [],
        omissions: [ { path: 'diagnostic', reason: 'byte_limit' } ]
      )
      expect(JSON.generate(detail[:diagnostic]).bytesize).to be <= 98_304
    end

    it 'local issueだけを記録できrefusal本文や任意の理由を受け付けない' do
      detail = described_class.build(local_issue: 'refusal')
      invalid = described_class.build(local_issue: 'private refusal text')

      expect(detail[:diagnostic]).to eq(
        schema_version: 'external_service_error_diagnostic_v1',
        nodes: [],
        omissions: [],
        local_issue: 'refusal'
      )
      expect(invalid.dig(:diagnostic, :local_issue)).to be_nil
      expect(invalid.dig(:diagnostic, :omissions)).to include(path: 'local_issue', reason: 'invalid_structure')
      expect(JSON.generate(invalid)).not_to include('private refusal text')
    end

    it '不正encodingの修復を記録し元のbytesをJSONへ持ち込まない' do
      detail = described_class.build(body: { error: { message: "Invalid\xFF image".force_encoding(Encoding::UTF_8) } })

      expect(detail.dig(:diagnostic, :nodes, 0, :message_safe)).to eq('Invalid image')
      expect(detail.dig(:diagnostic, :omissions)).to include(path: 'error.message', reason: 'invalid_encoding')
      expect { JSON.generate(detail) }.not_to raise_error
    end

    it '異なる省略理由がある場合も保存後の順序を維持する' do
      detail = described_class.build(
        body: {
          error: {
            code: [],
            innererror: { code: 'InvalidInput', message: 'Failure person@example.test' }
          }
        }
      )
      stored = JSON.parse(JSON.generate(detail)).deep_symbolize_keys

      expect(described_class.build(**stored)).to eq(detail)
    end
  end
end
