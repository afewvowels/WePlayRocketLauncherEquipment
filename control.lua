local NAME = "wp-personal-rocket-launcher-equipment"
local RETRY_TICKS = 30

local function launcher_data()
  return prototypes.mod_data["prl-launcher-data"].data
end

local function is_launcher(name)
  return name == NAME or launcher_data().variants[name] ~= nil
end

local function get_state(index)
  storage.players = storage.players or {}
  local s = storage.players[index]
  if not s then
    s = { disabled = false }
    storage.players[index] = s
  end
  return s
end

-- Ammo the player allows, best first: their priority list, then any other
-- rocket ammo (like modded rockets) alphabetically. Nukes only if allowed.
local order_cache = {}
local function ammo_order(player)
  local cached = order_cache[player.index]
  if cached then return cached end
  local player_settings = settings.get_player_settings(player)
  local allow_atomic = player_settings["prl-allow-atomic"].value
  local all = launcher_data().ammo
  local order, seen = {}, {}
  local function add(name)
    local info = all[name]
    if info and not seen[name] and (allow_atomic or not info.atomic) then
      seen[name] = true
      order[#order + 1] = name
    end
  end
  for word in string.gmatch(player_settings["prl-ammo-priority"].value, "[^,%s]+") do add(word) end
  local rest = {}
  for name in pairs(all) do
    if not seen[name] then rest[#rest + 1] = name end
  end
  table.sort(rest)
  for _, name in ipairs(rest) do add(name) end
  order_cache[player.index] = order
  return order
end

-- Take one rocket of the best allowed type; returns its name
local function take_ammo(inventory, order)
  local all = launcher_data().ammo
  local first = {}
  for i = 1, #inventory do
    local stack = inventory[i]
    if stack.valid_for_read and all[stack.name] and not first[stack.name] then
      first[stack.name] = stack
    end
  end
  for _, name in ipairs(order) do
    local stack = first[name]
    if stack then
      if stack.count > 1 then stack.count = stack.count - 1 else stack.clear() end
      return name
    end
  end
end

local function swap(grid, eq, new_name)
  local position, quality, old_name = eq.position, eq.quality.name, eq.name
  grid.take({ equipment = eq })
  local new = grid.put({ name = new_name, quality = quality, position = position })
  return new or grid.put({ name = old_name, quality = quality, position = position })
end

-- Empty launchers (energy 0) load one rocket: swap to the copy that fires
-- that ammo at this launcher's quality, then give it 1J = one shot.
local function reload(player, character, state, tick)
  if state.next_check and tick < state.next_check then return end
  local grid = character.grid
  if not grid then return end
  local inventory, order
  for _, eq in pairs(grid.equipment) do
    if eq.energy < 1 and is_launcher(eq.name) then
      inventory = inventory or character.get_inventory(defines.inventory.character_main)
      order = order or ammo_order(player)
      local ammo = inventory and take_ammo(inventory, order)
      if not ammo then
        state.next_check = tick + RETRY_TICKS
        return
      end
      local want = NAME .. "-" .. ammo .. "-" .. eq.quality.name
      if eq.name ~= want and prototypes.equipment[want] then eq = swap(grid, eq, want) end
      if eq then eq.energy = 1 end
    end
  end
  state.next_check = nil
end

-- Take loaded rockets back out and return them to the inventory
local function unload(character)
  local grid = character.grid
  if not grid then return end
  local variants = launcher_data().variants
  for _, eq in pairs(grid.equipment) do
    local info = variants[eq.name]
    if info and eq.energy >= 1 then
      eq.energy = 0
      local stack = { name = info.ammo, count = 1 }
      if character.insert(stack) == 0 then
        character.surface.spill_item_stack({ position = character.position, stack = stack })
      end
    end
  end
end

script.on_event(defines.events.on_tick, function(event)
  for _, player in pairs(game.connected_players) do
    local character = player.character
    if character and character.valid then
      local state = get_state(player.index)
      if not state.disabled then reload(player, character, state, event.tick) end
    end
  end
end)

-- New rockets in the inventory: try loading right away
script.on_event(defines.events.on_player_main_inventory_changed, function(event)
  get_state(event.player_index).next_check = nil
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.player_index then
    order_cache[event.player_index] = nil
    get_state(event.player_index).next_check = nil
  end
end)

script.on_event("prl-toggle", function(event)
  local player = game.get_player(event.player_index)
  local state = get_state(event.player_index)
  state.disabled = not state.disabled
  if state.disabled and player.character then unload(player.character) end
  player.create_local_flying_text({
    text = state.disabled and { "prl.disabled" } or { "prl.enabled" },
    create_at_cursor = true,
  })
end)

local function init()
  storage.players = storage.players or {}
  storage.blocked = nil
  order_cache = {}
end
script.on_init(init)
script.on_configuration_changed(init)
