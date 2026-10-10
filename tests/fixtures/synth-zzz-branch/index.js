// Synthetic branch fixture: real transitive dependency (is-odd@3.0.1 ->
// is-number@6.0.0 per the frozen lock). Importing check() proves the
// fetcher preserved the full transitive closure, not just symlink shape.
import isOdd from 'is-odd'

export const branchName = '@dsh-synth/zzz-branch'
export function check (n) {
  return isOdd(n)
}
export default { branchName, check }
