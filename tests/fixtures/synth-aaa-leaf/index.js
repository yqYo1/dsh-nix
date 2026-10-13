// Synthetic leaf fixture: no runtime dependencies. Importing answer()
// proves direct-spec projection yields a loadable module.
export const leafName = '@dsh-synth/aaa-leaf'
export function answer () {
  return 42
}
export default { leafName, answer }
