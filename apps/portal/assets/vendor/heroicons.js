const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function({matchComponents, theme}) {
  // Portal lives in an umbrella, so deps are fetched to the umbrella root, not
  // to apps/portal/deps. The pre-umbrella path only still resolves on machines
  // that have a stale apps/portal/deps lying around; on a clean checkout it
  // does not exist and `mix assets.deploy` dies on ENOENT.
  let iconsDir = [
    path.join(__dirname, "../../../../deps/heroicons/optimized"),
    path.join(__dirname, "../../deps/heroicons/optimized")
  ].find(candidate => fs.existsSync(candidate))

  if (!iconsDir) {
    throw new Error("heroicons dep not found; run `mix deps.get` before building assets")
  }
  let values = {}
  let icons = [
    ["", "/24/outline"],
    ["-solid", "/24/solid"],
    ["-mini", "/20/solid"],
    ["-micro", "/16/solid"]
  ]
  icons.forEach(([suffix, dir]) => {
    fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
      let name = path.basename(file, ".svg") + suffix
      values[name] = {name, fullPath: path.join(iconsDir, dir, file)}
    })
  })
  matchComponents({
    "hero": ({name, fullPath}) => {
      let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
      content = encodeURIComponent(content)
      let size = theme("spacing.6")
      if (name.endsWith("-mini")) {
        size = theme("spacing.5")
      } else if (name.endsWith("-micro")) {
        size = theme("spacing.4")
      }
      return {
        [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--hero-${name})`,
        "mask": `var(--hero-${name})`,
        "mask-repeat": "no-repeat",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "width": size,
        "height": size
      }
    }
  }, {values})
})
