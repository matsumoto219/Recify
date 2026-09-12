import assert from 'node:assert/strict'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import stylelint from 'stylelint'

const configFile = fileURLToPath(new URL('../../.stylelintrc.json', import.meta.url))
const codeFilename = fileURLToPath(new URL('../../app/assets/tailwind/application.css', import.meta.url))

test('keeps prelude validation enabled with only media and apply exceptions', async () => {
  const config = await stylelint.resolveConfig(codeFilename, { configFile })

  assert.deepEqual(config.rules['at-rule-prelude-no-invalid'], [
    true,
    { ignoreAtRules: ['media', 'apply'] }
  ])
})

for (const [name, code] of [
  ['Tailwind arbitrary blur', '.ambient-glow { @apply blur-[120px]; }'],
  ['Tailwind backdrop blur', '.modal-overlay { @apply backdrop-blur-sm; }'],
  ['standard supports prelude', '@supports (display: grid) { .example { display: grid; } }']
]) {
  test(`accepts ${name}`, async () => {
    const result = await stylelint.lint({ code, codeFilename, configFile })

    assert.equal(result.errored, false)
    assert.deepEqual(result.results[0].warnings, [])
  })
}

for (const [name, code, rule] of [
  ['invalid supports prelude', '@supports nonsense { .example { color: red; } }', 'at-rule-prelude-no-invalid'],
  ['invalid import prelude', '@import 123;', 'at-rule-prelude-no-invalid'],
  ['invalid media query', '@media screen and { .example { color: red; } }', 'media-query-no-invalid'],
  ['unknown property beside apply', '.example { @apply backdrop-blur-sm; unknown-property: 1; }', 'property-no-unknown'],
  ['misspelled apply directive', '.example { @appli backdrop-blur-sm; }', 'at-rule-no-unknown']
]) {
  test(`rejects ${name}`, async () => {
    const result = await stylelint.lint({ code, codeFilename, configFile })

    assert.equal(result.errored, true)
    assert.ok(result.results[0].warnings.some((warning) => warning.rule === rule && warning.severity === 'error'))
  })
}
