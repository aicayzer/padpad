import assert from 'node:assert/strict'
import { test } from 'node:test'
import { scope } from './ci-scope.mjs'

const none = { editor: false, app: false, ui: false }

test('prose, design, records and repository metadata run no lane', () => {
  for (const path of [
    'README.md',
    'AGENTS.md',
    'DEVELOPMENT.md',
    'editor/BRIDGE.md',
    'Design/Screenshots/padpad-markdown.png',
    'marfa/Notes/a.md',
    '.gitignore',
    'scripts/ci-scope.test.mjs',
    '.github/CODEOWNERS',
  ]) {
    assert.deepEqual(scope([path]), none, path)
  }
})

test('application and test changes run the app and UI lanes only', () => {
  for (const path of ['App/AppDelegate.swift', 'UITests/PadUITests.swift', 'project.yml']) {
    assert.deepEqual(scope([path]), { editor: false, app: true, ui: true }, path)
  }
})

test('unit tests and release tooling skip the UI lane', () => {
  for (const path of ['Tests/DocumentTests.swift', 'scripts/validate-release.sh', 'ci_scripts/ci_post_clone.sh']) {
    assert.deepEqual(scope([path]), { editor: false, app: true, ui: false }, path)
  }
})

test('editor sources run every lane because the app bundles them', () => {
  assert.deepEqual(scope(['editor/src/main.ts']), { editor: true, app: true, ui: true })
})

test('the workflow and this script run every lane; an empty change keeps all', () => {
  const all = { editor: true, app: true, ui: true }
  assert.deepEqual(scope(['.github/workflows/ci.yml']), all)
  assert.deepEqual(scope(['scripts/ci-scope.mjs']), all)
  assert.deepEqual(scope([]), all)
})

test('prose beside code does not hide the code', () => {
  assert.deepEqual(scope(['README.md', 'App/Commands.swift']), { editor: false, app: true, ui: true })
})
