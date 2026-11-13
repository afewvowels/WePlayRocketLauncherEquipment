local NAME = "wp-personal-rocket-launcher-equipment"
local NO_AMMO_RETRY = 120 -- ticks before a grid with no rockets looks again

-- How it works:
-- Each launcher holds one rocket as 1J of energy (it never charges from the grid).
-- We keep a list of only the equipment grids that contain launchers
-- (storage.grids). Each grid has a magazine: a whole stack of rockets taken from
-- its owner's inventory at once, so the inventory is only touched once per stack.
-- Grids are checked every few ticks, each on its own tick within the interval,
-- so the work is spread out in multiplayer.
-- Grids belong to a character (armor), a spidertron or a car, and take rockets
-- from the main inventory or trunk.

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

---------------------------------------------------------------------------
-- Ammo order
---------------------------------------------------------------------------

-- Allowed ammo, best first: the priority list, then any other rocket ammo
-- (like modded rockets) alphabetically. Nukes only if allowed.
-- Returns { list = {names...}, allowed = {name = true} }.
local function build_order(priority, allow_atomic)
  local all = launcher_data().ammo
  local list, allowed = {}, {}
  local function add(name)
    local info = all[name]
    if info and not allowed[name] and (allow_atomic or not info.atomic) then
      allowed[name] = true
      list[#list + 1] = name
    end
  end
  for word in string.gmatch(priority, "[^,%s]+") do add(word) end
  local rest = {}
  for name in pairs(all) do
    if not allowed[name] then rest[#rest + 1] = name end
  end
  table.sort(rest)
  for _, name in ipairs(rest) do add(name) end
  return { list = list, allowed = allowed }
end

-- These caches only hold values derived from settings, so they're safe to
-- rebuild at any time (including after loading a save).
local order_cache = {}
local default_order

local function player_order(player)
  local cached = order_cache[player.index]
  if cached then return cached end
  local player_settings = settings.get_player_settings(player)
  local order = build_order(player_settings["prl-ammo-priority"].value, player_settings["prl-allow-atomic"].value)
  order_cache[player.index] = order
  return order
end

-- For vehicles with no driver: the default priority, never atomic
local function no_player_order()
  if not default_order then
    default_order = build_order(prototypes.mod_setting["prl-ammo-priority"].default_value, false)
  end
  return default_order
end

---------------------------------------------------------------------------
-- Inventory
---------------------------------------------------------------------------

-- Take a whole stack of the best allowed rocket, using the lowest quality
-- stack of that rocket so normal rockets go before fancy ones.
-- Returns a magazine { name, quality, count } or nil. `count` is in shots,
-- not items: one item holds magazine_size shots, and the top item of a
-- stack may already be partly used (stack.ammo).
local function take_stack(inventory, order)
  local all = launcher_data().ammo
  local best = {}
  for i = 1, #inventory do
    local stack = inventory[i]
    if stack.valid_for_read and all[stack.name] then
      local current = best[stack.name]
      if not current or stack.quality.level < current.quality.level then
        best[stack.name] = stack
      end
    end
  end
  for _, name in ipairs(order.list) do
    local stack = best[name]
    if stack then
      local size = all[name].magazine or 1
      local shots = (stack.count - 1) * size + (size > 1 and stack.ammo or 1)
      local mag = { name = name, quality = stack.quality.name, count = shots }
      stack.clear()
      return mag
    end
  end
end

local function put_or_spill(target, surface, position, stack)
  local inserted = target and target.insert(stack) or 0
  if inserted < stack.count and surface then
    stack.count = stack.count - inserted
    surface.spill_item_stack({ position = position, stack = stack })
  end
end

-- Give shots back to a player or inventory as items: full items, plus one
-- partly used item for any leftover shots. Spills whatever doesn't fit.
local function give_back(target, surface, position, name, quality, shots)
  local info = launcher_data().ammo[name]
  local size = info and info.magazine or 1
  local full = math.floor(shots / size)
  local partial = shots - full * size
  if full > 0 then
    put_or_spill(target, surface, position, { name = name, count = full, quality = quality })
  end
  if partial > 0 then
    put_or_spill(target, surface, position, { name = name, count = 1, quality = quality, ammo = partial })
  end
end

---------------------------------------------------------------------------
-- Grid tracking
---------------------------------------------------------------------------

local swapping = false -- our own take/put fires equipment events; ignore those

local function pos_key(position)
  return position.x .. "," .. position.y
end

-- The entity a grid belongs to and the inventory its rockets live in
local function grid_owner(grid)
  local owner = grid.entity_owner
  if not (owner and owner.valid) then return end -- armor that isn't being worn
  if owner.type == "character" then
    return owner, owner.get_inventory(defines.inventory.character_main)
  elseif owner.type == "spider-vehicle" then
    return owner, owner.get_inventory(defines.inventory.spider_trunk)
  elseif owner.type == "car" then
    return owner, owner.get_inventory(defines.inventory.car_trunk)
  end
end

-- Give rockets back to the grid's owner, or to `player` (optional) when the
-- grid has no owner, e.g. armor being edited in an inventory.
-- Returns false if there's nobody to give them to yet.
local function deliver(entry, player, name, quality, count)
  local owner, inventory = grid_owner(entry.grid)
  if owner then
    give_back(inventory, owner.surface, owner.position, name, quality, count)
  elseif player and player.valid then
    give_back(player, player.surface, player.position, name, quality, count)
  else
    return false
  end
  return true
end

-- Return a grid's magazine. Returns true if the magazine is empty afterwards.
-- Loaded rockets waiting to go back that match the magazine are added to it
-- first, so the shots combine into whole items.
local function return_magazine(entry, player)
  local mag = entry.mag
  if not mag then return true end
  local others = {}
  for _, rocket in pairs(entry.orphans) do
    if rocket.ammo == mag.name and rocket.quality == mag.quality then
      mag.count = mag.count + 1
    else
      others[#others + 1] = rocket
    end
  end
  entry.orphans = others
  if not deliver(entry, player, mag.name, mag.quality, mag.count) then
    return false -- nowhere to put it yet; keep it with the grid
  end
  entry.mag = nil
  return true
end

-- Rockets that were loaded in launchers that have since been removed.
-- Returns true when all of them have been given back.
local function return_orphans(entry, player)
  if #entry.orphans == 0 then return true end
  -- Group by rocket and quality so leftover shots combine into whole items
  local groups = {}
  for _, rocket in pairs(entry.orphans) do
    local key = rocket.ammo .. "|" .. rocket.quality
    local group = groups[key]
    if group then
      group.shots = group.shots + 1
    else
      groups[key] = { ammo = rocket.ammo, quality = rocket.quality, shots = 1 }
    end
  end
  local kept = {}
  for _, group in pairs(groups) do
    if not deliver(entry, player, group.ammo, group.quality, group.shots) then
      for _ = 1, group.shots do kept[#kept + 1] = { ammo = group.ammo, quality = group.quality } end
    end
  end
  entry.orphans = kept
  return #kept == 0
end

-- Rebuild a grid's launcher list. Launchers that were removed while loaded
-- give their rocket back. Drops the grid once it has no launchers (after
-- returning its magazine).
local function track(grid, player)
  if not (grid and grid.valid) then return end
  storage.grids = storage.grids or {}
  local id = grid.unique_id
  local launchers, present = {}, {}
  for _, eq in pairs(grid.equipment) do
    if is_launcher(eq.name) then
      launchers[#launchers + 1] = eq
      present[pos_key(eq.position)] = true
    end
  end
  local entry = storage.grids[id]
  if not entry then
    if #launchers == 0 then return end
    -- mag: rockets taken from the inventory but not loaded yet
    -- loaded: the rocket in each launcher, by grid position { ammo, quality }
    -- orphans: rockets from removed launchers still waiting to be given back
    storage.grids[id] = { grid = grid, launchers = launchers, loaded = {}, orphans = {} }
    return
  end

  for key, rocket in pairs(entry.loaded) do
    if not present[key] then
      entry.orphans[#entry.orphans + 1] = rocket
      entry.loaded[key] = nil
    end
  end
  if #launchers == 0 then
    local mag_done = return_magazine(entry, player)
    if return_orphans(entry, player) and mag_done then
      storage.grids[id] = nil
    else
      entry.launchers = {}
    end
    return
  end
  return_orphans(entry, player)
  entry.launchers = launchers
  entry.next_check = nil
end

local function swap(grid, eq, new_name)
  local position, quality, old_name = eq.position, eq.quality.name, eq.name
  swapping = true
  grid.take({ equipment = eq })
  local new = grid.put({ name = new_name, quality = quality, position = position })
    or grid.put({ name = old_name, quality = quality, position = position })
  swapping = false
  return new
end

-- Whose settings pick a grid's rockets. Returns nil when it shouldn't fire.
local function grid_order(owner)
  local player
  if owner.type == "character" then
    player = owner.player
    if player and get_state(player.index).disabled then return end
  else
    local driver = owner.get_driver()
    if driver and driver.object_name == "LuaEntity" then driver = driver.player end
    player = driver
  end
  return player and player_order(player) or no_player_order()
end

-- Out of rockets: turn empty launchers back into the plain launcher, whose
-- grid sprite shows the red "needs ammo" icon. Loaded ones keep firing.
local function show_empty(entry, from)
  local grid, launchers = entry.grid, entry.launchers
  for i = from, #launchers do
    local eq = launchers[i]
    if eq.valid and eq.energy < 1 then
      entry.loaded[pos_key(eq.position)] = nil
      if eq.name ~= NAME then launchers[i] = swap(grid, eq, NAME) end
    end
  end
end

-- Load every empty launcher in one grid from its magazine
local function service(entry, tick)
  if entry.next_check and tick < entry.next_check then return end
  local grid = entry.grid
  local launchers = entry.launchers
  local owner, inventory, order
  for i = 1, #launchers do
    local eq = launchers[i]
    if not eq.valid then
      track(grid) -- something changed without an event; rebuild and try next time
      return
    end
    if eq.energy < 1 then
      if not owner then
        owner, inventory = grid_owner(grid)
        if not (owner and inventory) then return end
        order = grid_order(owner)
        if not order then return end
        -- Settings changed (e.g. atomic turned off): return rockets that aren't allowed
        if entry.mag and not order.allowed[entry.mag.name] then return_magazine(entry) end
      end
      if not entry.mag then
        entry.mag = take_stack(inventory, order)
        if not entry.mag then
          show_empty(entry, i)
          entry.next_check = tick + NO_AMMO_RETRY
          return
        end
      end
      local mag = entry.mag
      local ammo, quality = mag.name, mag.quality
      mag.count = mag.count - 1
      if mag.count <= 0 then entry.mag = nil end

      local want = NAME .. "-" .. ammo .. "-" .. eq.quality.name
      if eq.name ~= want and prototypes.equipment[want] then
        eq = swap(grid, eq, want)
        launchers[i] = eq
      end
      if eq then
        eq.energy = 1
        entry.loaded[pos_key(eq.position)] = { ammo = ammo, quality = quality }
      end
    end
  end
end

script.on_event(defines.events.on_tick, function(event)
  local grids = storage.grids
  if not grids or not next(grids) then return end
  local interval = settings.global["prl-check-interval"].value
  local slot = event.tick % interval
  for id, entry in pairs(grids) do
    if id % interval == slot then
      if entry.grid.valid then
        service(entry, event.tick)
      else
        grids[id] = nil
      end
    end
  end
end)

local function character_entry(player)
  local character = player and player.character
  if not (character and character.valid and character.grid) then return end
  return storage.grids and storage.grids[character.grid.unique_id]
end

---------------------------------------------------------------------------
-- Events that change which grids hold launchers
---------------------------------------------------------------------------

local function on_equipment_changed(event)
  if swapping then return end
  local equipment = event.equipment
  local name = type(equipment) == "string" and equipment or (equipment and equipment.valid and equipment.name)
  if name and is_launcher(name) then
    track(event.grid, event.player_index and game.get_player(event.player_index))
  end
end
script.on_event(defines.events.on_equipment_inserted, on_equipment_changed)
script.on_event(defines.events.on_equipment_removed, on_equipment_changed)
script.on_event(defines.events.on_player_placed_equipment, on_equipment_changed)
script.on_event(defines.events.on_player_removed_equipment, on_equipment_changed)

-- Putting on armor that already has launchers (e.g. from a chest)
script.on_event(defines.events.on_player_armor_inventory_changed, function(event)
  local player = game.get_player(event.player_index)
  local character = player and player.character
  if character and character.valid then track(character.grid) end
end)

-- Placing a vehicle that already has launchers in its grid
local function on_built(event)
  local entity = event.entity
  if entity and entity.valid and entity.grid then track(entity.grid) end
end
local vehicle_filter = { { filter = "type", type = "car" }, { filter = "type", type = "spider-vehicle" } }
script.on_event(defines.events.on_built_entity, on_built, vehicle_filter)
script.on_event(defines.events.on_robot_built_entity, on_built, vehicle_filter)
script.on_event(defines.events.script_raised_built, on_built, vehicle_filter)

-- New rockets picked up: a character with an empty magazine looks right away
script.on_event(defines.events.on_player_main_inventory_changed, function(event)
  local entry = character_entry(game.get_player(event.player_index))
  if entry then entry.next_check = nil end
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.player_index then
    order_cache[event.player_index] = nil
    local entry = character_entry(game.get_player(event.player_index))
    if entry then entry.next_check = nil end
  end
end)

---------------------------------------------------------------------------
-- Toggle
---------------------------------------------------------------------------

-- Take loaded rockets and the magazine out of a character's armor and give them back
local function unload(character)
  local grid = character.grid
  if not grid then return end
  local variants = launcher_data().variants
  local entry = storage.grids and storage.grids[grid.unique_id]
  local inventory = character.get_inventory(defines.inventory.character_main)
  for _, eq in pairs(grid.equipment) do
    local info = variants[eq.name]
    if info and eq.energy >= 1 then
      eq.energy = 0
      local key = pos_key(eq.position)
      local rocket = entry and entry.loaded[key]
      if entry then
        entry.loaded[key] = nil
        -- returned together below, so leftover shots combine into whole items
        entry.orphans[#entry.orphans + 1] = { ammo = info.ammo, quality = rocket and rocket.quality or "normal" }
      else
        give_back(inventory, character.surface, character.position, info.ammo, "normal", 1)
      end
    end
  end
  if entry then
    return_magazine(entry)
    return_orphans(entry)
    show_empty(entry, 1) -- toggled off: show them as not loaded
  end
end

script.on_event("prl-toggle", function(event)
  local player = game.get_player(event.player_index)
  local state = get_state(event.player_index)
  state.disabled = not state.disabled
  if state.disabled and player.character then unload(player.character) end
  local entry = character_entry(player)
  if entry then entry.next_check = nil end
  player.create_local_flying_text({
    text = state.disabled and { "prl.disabled" } or { "prl.enabled" },
    create_at_cursor = true,
  })
end)

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

-- Find every grid with launchers: worn armor and vehicles on every surface.
-- Armor in chests is picked up when someone puts it on.
local function scan_all()
  storage.grids = storage.grids or {}
  -- Forget grids that were destroyed while the mod wasn't looking,
  -- and fill in fields that test builds of 0.4.0 didn't have
  for id, entry in pairs(storage.grids) do
    if not entry.grid.valid then
      storage.grids[id] = nil
    else
      entry.loaded = entry.loaded or {}
      entry.orphans = entry.orphans or {}
      entry.loaded_quality = nil
    end
  end
  for _, player in pairs(game.players) do
    local character = player.character
    if character and character.valid then track(character.grid) end
  end
  for _, surface in pairs(game.surfaces) do
    for _, vehicle in pairs(surface.find_entities_filtered({ type = { "car", "spider-vehicle" } })) do
      if vehicle.grid then track(vehicle.grid) end
    end
  end
end

local function init()
  storage.players = storage.players or {}
  storage.blocked = nil -- left over from 0.3.1
  for _, state in pairs(storage.players) do state.next_check = nil end -- left over from 0.3.3
  order_cache = {}
  default_order = nil
  scan_all()
end
script.on_init(init)
script.on_configuration_changed(init)
