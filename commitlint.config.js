module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Disable body length limits - allow detailed commit messages
    'body-max-line-length': [0, 'always', Infinity],
    'body-max-length': [0, 'always', Infinity],
    // Keep subject line reasonable but not too strict
    'header-max-length': [2, 'always', 100],
    // Allow longer footers for breaking changes, etc.
    'footer-max-line-length': [0, 'always', Infinity],
  },
};
