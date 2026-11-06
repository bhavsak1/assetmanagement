import js from '@eslint/js'
import tseslint from 'typescript-eslint'

export default tseslint.config(js.configs.recommended, tseslint.configs.recommended, {
  // Story 10.1, CLAUDE.md §11: every model call goes through src/ai.ts.
  ignores: ['src/ai.ts'],
  rules: {
    'no-restricted-imports': ['error', { patterns: [{ group: ['@anthropic-ai/*', 'openai', '@google/genai'], message: 'Model calls go through src/ai.ts (CLAUDE.md §11).' }] }],
  },
})
