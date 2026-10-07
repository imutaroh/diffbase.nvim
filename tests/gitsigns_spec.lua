local h = require("helpers")

local T = {}

local function db()
  return require("diffbase")
end

local TOGGLES = { "toggle_linehl", "toggle_numhl", "toggle_word_diff", "toggle_deleted" }

local function toggles(fake)
  return #vim.tbl_filter(function(c)
    return c[1]:match("^toggle_") ~= nil
  end, fake.calls)
end

---Wait until `n` toggle calls were made in total (they run in change_base's callback).
local function wait_toggles(fake, n)
  h.wait_for(function()
    return toggles(fake) >= n
  end, n .. " toggle calls")
end

local function on(fx, fake, n)
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  if fake then
    wait_toggles(fake, n or 4)
  end
end

local function off(fake, n)
  db().off()
  wait_toggles(fake, n or 8)
end

local function flags(cfg)
  return { linehl = cfg.linehl, numhl = cfg.numhl, word_diff = cfg.word_diff, show_deleted = cfg.show_deleted }
end

T["ON enables everything and sets the base globally"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns()
  on(fx, fake)
  h.eq({ { "change_base", fx.second, true } }, h.calls_of(fake.calls, "change_base"))
  for _, fn in ipairs(TOGGLES) do
    h.eq({ { fn, true } }, h.calls_of(fake.calls, fn), fn)
  end
  h.eq({ linehl = true, numhl = true, word_diff = true, show_deleted = true }, flags(fake.config))
  h.eq(fx.second, fake.config.base)
  h.ok(require("diffbase.integrations.gitsigns").is_active())
end

T["OFF restores the user's values exactly (mixed flags, no base)"] = function()
  local fx = h.fixture()
  local user = { linehl = false, numhl = true, word_diff = false, show_deleted = true }
  local fake = h.fake_gitsigns(user)
  on(fx, fake)
  off(fake)
  h.eq(user, flags(fake.config))
  h.eq(nil, fake.config.base)
  h.eq({ { "change_base", fx.second, true }, { "change_base", nil, true } }, h.calls_of(fake.calls, "change_base"))
  h.eq({ { "toggle_linehl", true }, { "toggle_linehl", false } }, h.calls_of(fake.calls, "toggle_linehl"))
  h.eq({ { "toggle_numhl", true }, { "toggle_numhl", true } }, h.calls_of(fake.calls, "toggle_numhl"))
  h.ok(not require("diffbase.integrations.gitsigns").is_active())
end

T["OFF restores a user-set base with change_base"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns({ base = "v0.1", linehl = true })
  on(fx, fake)
  off(fake)
  h.eq("v0.1", fake.config.base)
  h.eq({ "change_base", "v0.1", true }, h.calls_of(fake.calls, "change_base")[2])
  h.eq({}, h.calls_of(fake.calls, "reset_base"), "reset_base takes no callback")
  h.eq(true, fake.config.linehl)
end

T["switching bases keeps the first snapshot"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns()
  on(fx, fake)
  h.on_and_wait(function()
    return db().set("HEAD~2")
  end)
  wait_toggles(fake, 8)
  h.eq({ "change_base", fx.init, true }, h.calls_of(fake.calls, "change_base")[2])
  off(fake, 12)
  h.eq({ linehl = false, numhl = false, word_diff = false, show_deleted = false }, flags(fake.config))
  h.eq(nil, fake.config.base)
end

T["flags disabled in diffbase config are never touched"] = function()
  local fx = h.fixture()
  db().setup({ gitsigns = { numhl = false, show_deleted = false } })
  local fake = h.fake_gitsigns({ numhl = true })
  on(fx, fake, 2)
  off(fake, 4)
  h.eq({}, h.calls_of(fake.calls, "toggle_numhl"))
  h.eq({}, h.calls_of(fake.calls, "toggle_deleted"))
  h.eq(2, #h.calls_of(fake.calls, "toggle_linehl"))
  h.eq(true, fake.config.numhl)
end

T["gitsigns.enabled = false: no calls at all"] = function()
  local fx = h.fixture()
  db().setup({ gitsigns = { enabled = false } })
  local fake = h.fake_gitsigns()
  on(fx)
  db().off()
  h.settle(30)
  h.eq({}, fake.calls)
end

T["user changes while ON are overridden by the snapshot on OFF"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns({ word_diff = true })
  on(fx, fake)
  fake.gs.toggle_word_diff(false) -- user toggles while ON
  off(fake, 9)
  h.eq(true, fake.config.word_diff, "restored to the value at ON time")
end

T["missing gitsigns.config and failing calls do not error"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns({ linehl = true })
  package.loaded["gitsigns.config"] = nil
  package.preload["gitsigns.config"] = function()
    error("no config module")
  end
  fake.gs.toggle_numhl = function()
    error("boom")
  end
  fake.gs.toggle_deleted = nil
  local ok, err = pcall(function()
    on(fx, fake, 2)
    off(fake, 4)
  end)
  package.preload["gitsigns.config"] = nil
  h.ok(ok, tostring(err))
  h.no_warnings()
  -- Without a readable config the snapshot falls back to "off" for the enabled flags.
  h.eq(false, fake.config.linehl)
end

T["a change_base that throws still applies the toggles"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns()
  fake.gs.change_base = function()
    error("boom")
  end
  on(fx, fake)
  off(fake)
  h.eq({ linehl = false, numhl = false, word_diff = false, show_deleted = false }, flags(fake.config))
  h.no_warnings()
end

T["gitsigns loaded after diffbase turned on is used on the next change"] = function()
  local fx = h.fixture()
  on(fx)
  local fake = h.fake_gitsigns()
  h.on_and_wait(function()
    return db().set("HEAD~2")
  end)
  wait_toggles(fake, 4)
  h.eq({ { "change_base", fx.init, true } }, h.calls_of(fake.calls, "change_base"))
  off(fake)
  h.eq(nil, fake.config.base)
  h.eq(false, fake.config.linehl)
end

T["toggles run in change_base's callback, after it finished (ON and OFF)"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns()
  fake.delay_ms = 30
  h.edit(fx.dir .. "/README.md")
  h.eq(true, db().set_preset("previous"))
  h.eq(fx.second, fake.config.base, "the base is set at once")
  h.eq(0, toggles(fake), "no toggle before change_base called back")
  wait_toggles(fake, 4)
  db().off()
  h.eq(4, toggles(fake), "no restore before change_base called back")
  wait_toggles(fake, 8)
  h.eq({}, fake.overlaps, "no toggle while change_base was still updating buffers")
  h.eq({ linehl = false, numhl = false, word_diff = false, show_deleted = false }, flags(fake.config))
end

T["a superseded ON's callback does nothing"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns()
  fake.delay_ms = 30
  h.edit(fx.dir .. "/README.md")
  h.eq(true, db().set("HEAD~1"))
  h.eq(true, db().set("HEAD~2"))
  wait_toggles(fake, 4)
  h.settle(80) -- let the first change_base call back too
  h.eq(4, toggles(fake), "toggles applied once, by the current ON")
  h.eq(fx.init, fake.config.base)
  h.eq({}, fake.overlaps)
end

T["OFF then ON in the same tick: the new base wins and OFF still restores the user's values"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns({ linehl = false, numhl = true, base = "v3" })
  fake.delay_ms = 30
  on(fx, fake)
  db().off()
  h.on_and_wait(function()
    return db().set("HEAD~2")
  end)
  wait_toggles(fake, 8)
  h.settle(80) -- let the superseded OFF's callback arrive
  h.eq(8, toggles(fake), "the superseded OFF restored nothing")
  h.eq(fx.init, fake.config.base)
  h.eq(true, fake.config.linehl)
  off(fake, 12)
  h.eq("v3", fake.config.base, "the snapshot from the first ON")
  h.eq(false, fake.config.linehl)
  h.eq(true, fake.config.numhl)
end

T["ON then OFF in the same tick: OFF wins"] = function()
  local fx = h.fixture()
  local fake = h.fake_gitsigns({ numhl = true })
  fake.delay_ms = 30
  h.edit(fx.dir .. "/README.md")
  h.eq(true, db().set_preset("previous"))
  db().off()
  wait_toggles(fake, 4)
  h.settle(80)
  h.eq(4, toggles(fake), "only OFF's restore ran")
  h.eq({ linehl = false, numhl = true, word_diff = false, show_deleted = false }, flags(fake.config))
  h.eq(nil, fake.config.base)
end

return T
