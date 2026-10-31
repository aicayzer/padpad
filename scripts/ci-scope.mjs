// Decides which CI lanes a change needs, from the paths it touches.
import { execFileSync } from 'node:child_process'
import { appendFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

export function scope(paths) {
  // Nothing here reaches the app: prose, design assets, local records and repository metadata.
  const inert = (path) =>
    /^[^/]+\.md$/.test(path) ||
    path === 'editor/BRIDGE.md' ||
    path === 'LICENSE' ||
    path === '.gitignore' ||
    path === 'scripts/ci-scope.test.mjs' ||
    path === '.infisical.json' ||
    /^(Design|marfa)\//.test(path) ||
    (path.startsWith('.github/') && path !== '.github/workflows/ci.yml')
  // Release tooling and unit tests cannot change what the UI tests drive.
  const unitOnly = (path) =>
    (/^(scripts|ci_scripts)\//.test(path) && path !== 'scripts/ci-scope.mjs') ||
    /^Tests\/[^/]+\.swift$/.test(path)
  const editor = (path) =>
    path.startsWith('editor/') ||
    path === '.github/workflows/ci.yml' ||
    path === 'scripts/ci-scope.mjs'
  const relevant = paths.filter((path) => !inert(path))
  return {
    editor: paths.length === 0 || relevant.some(editor),
    app: paths.length === 0 || relevant.length > 0,
    ui: paths.length === 0 || relevant.some((path) => !unitOnly(path)),
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const { EVENT, BASE, HEAD, GITHUB_OUTPUT } = process.env
  let result = { editor: true, app: true, ui: true }
  // Manual runs, or missing history, keep every lane.
  if (EVENT === 'pull_request' && BASE && !/^0+$/.test(BASE) && HEAD) {
    const paths = execFileSync(
      'git',
      ['diff', '--name-only', '--no-renames', '-z', `${BASE}...${HEAD}`],
      { encoding: 'utf8' },
    )
      .split('\0')
      .filter(Boolean)
    result = scope(paths)
  }
  const lines = Object.entries(result).map(([lane, run]) => `${lane}=${run}`)
  console.log(lines.join('\n'))
  if (GITHUB_OUTPUT) appendFileSync(GITHUB_OUTPUT, `${lines.join('\n')}\n`)
}
