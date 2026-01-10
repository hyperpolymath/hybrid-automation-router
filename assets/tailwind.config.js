// SPDX-License-Identifier: MPL-2.0
// HAR Tailwind CSS configuration

const plugin = require("tailwindcss/plugin")

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/har_web.ex",
    "../lib/har_web/**/*.*ex"
  ],
  theme: {
    extend: {
      colors: {
        brand: "#3b82f6",
      }
    },
  },
  plugins: [
    // Custom form styles
    plugin(({addBase, theme}) => {
      addBase({
        "[type='text']": { paddingLeft: theme("spacing.3"), paddingRight: theme("spacing.3") },
        "[type='email']": { paddingLeft: theme("spacing.3"), paddingRight: theme("spacing.3") },
        "[type='password']": { paddingLeft: theme("spacing.3"), paddingRight: theme("spacing.3") },
        "textarea": { paddingLeft: theme("spacing.3"), paddingRight: theme("spacing.3") },
        "select": { paddingLeft: theme("spacing.3"), paddingRight: theme("spacing.3") },
      })
    })
  ]
}
