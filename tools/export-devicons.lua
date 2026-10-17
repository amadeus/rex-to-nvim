---@diagnostic disable: undefined-global
-- Snapshot nvim-web-devicons' extension table, tagged with Neovim's own
-- filetype detection, into data/devicons.json.
--
-- Usage: nvim --headless --clean -l tools/export-devicons.lua <devicons-dir> <out.json>

local plugin_dir, out_path = arg[1], arg[2]
assert(plugin_dir and out_path, "usage: export-devicons.lua <devicons-dir> <out.json>")

local icons = dofile(plugin_dir .. "/lua/nvim-web-devicons/default/icons_by_file_extension.lua")

local entries = {}
for ext, icon in pairs(icons) do
  table.insert(entries, {
    ext = ext,
    name = icon.name,
    glyph = icon.icon,
    color = icon.color,
    filetype = vim.filetype.match({ filename = "x." .. ext }) or vim.NIL,
  })
end
table.sort(entries, function(a, b) return a.ext < b.ext end)

local file = assert(io.open(out_path, "w"))
file:write(vim.json.encode(entries), "\n")
file:close()
print(("wrote %d extensions to %s"):format(#entries, out_path))
