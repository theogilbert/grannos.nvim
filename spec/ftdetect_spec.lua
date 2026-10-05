-- Every query language a driver can speak (see connections.lua LANGUAGE_TO_FT)
-- must be recognised from its file extension by grannos alone, without relying
-- on the user's config.
describe("ftdetect", function()
  before_each(function()
    vim.cmd("runtime! ftdetect/*.lua")
  end)

  for ext, ft in pairs({
    cypher = "cypher",
    cyp    = "cypher",
    lucene = "lucene",
    mongo  = "mongo",
    promql = "promql",
  }) do
    it("detects ." .. ext .. " as " .. ft, function()
      assert.are.equal(ft, vim.filetype.match({ filename = "q." .. ext }))
    end)
  end
end)
