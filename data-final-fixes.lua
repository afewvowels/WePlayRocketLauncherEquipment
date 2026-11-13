local NAME = "wp-personal-rocket-launcher-equipment"
local base = data.raw["active-defense-equipment"][NAME]
local range = settings.startup["prl-range"].value
local atomic_min_range = settings.startup["prl-atomic-min-range"].value

local function is_nuke(name)
  return name:find("atomic") or name:find("nuclear") or name:find("nuke") or name:find("antimatter")
end

local function get_ammo_type(ammo)
  local ammo_type = ammo.ammo_type
  if ammo_type and ammo_type[1] then ammo_type = ammo_type[1] end
  return ammo_type
end

-- The ammo's own action, fired by the launcher. The buffer is 1J and each
-- shot costs 1J, so a launcher fires exactly once per rocket that control.lua loads.
local function launcher_ammo_type(ammo)
  local ammo_type = table.deepcopy(get_ammo_type(ammo))
  ammo_type.category = nil
  ammo_type.energy_consumption = "1J"
  return ammo_type
end

-- Small ammo icon in the corner of the grid sprite, so you can see what's loaded
local function ammo_icon_layer(ammo)
  local icon, size = ammo.icon, ammo.icon_size
  if not icon and ammo.icons and ammo.icons[1] then
    icon, size = ammo.icons[1].icon, ammo.icons[1].icon_size
  end
  if not icon then return nil end
  size = size or 64
  return {
    filename = icon, width = size, height = size,
    scale = 64 / size, shift = { 1, 1 }, priority = "medium",
  }
end

base.attack_parameters.ammo_type = launcher_ammo_type(data.raw.ammo["rocket"])

local qualities = {}
for quality_name, quality in pairs(data.raw.quality or {}) do
  if quality_name ~= "quality-unknown" and (quality.level or 0) >= 0 then
    qualities[quality_name] = quality.level or 0
  end
end
if not next(qualities) then qualities.normal = 0 end

local launcher_data = { ammo = {}, variants = {} }

-- Rocket-like: "rocket" or "missile" in the ammo's name or ammo category.
-- That covers vanilla rockets plus things like Krastorio 2's heavy and turret
-- rockets and Space Exploration's rockets.
local function is_rocket_like(name, category)
  local text = (name .. " " .. (category or "")):lower()
  return text:find("rocket") or text:find("missile")
end

-- Only ammo that fires a projectile works with the launcher's attack
local function fires_projectile(ammo_type)
  local actions = ammo_type.action
  if not actions then return false end
  if actions.type then actions = { actions } end
  for _, action in pairs(actions) do
    local deliveries = action.action_delivery
    if deliveries then
      if deliveries.type then deliveries = { deliveries } end
      for _, delivery in pairs(deliveries) do
        if delivery.type == "projectile" then return true end
      end
    end
  end
  return false
end

-- One hidden launcher per rocket ammo type and quality.
-- control.lua swaps to the right one when it loads a rocket.
for ammo_name, ammo in pairs(data.raw.ammo) do
  local ammo_type = get_ammo_type(ammo)
  local category = ammo.ammo_category or (ammo_type and ammo_type.category)
  if ammo_type and not ammo.hidden and category and data.raw["ammo-category"][category]
    and is_rocket_like(ammo_name, category) and fires_projectile(ammo_type) then
    local atomic = is_nuke(ammo_name) and true or false
    -- magazine: shots per item (vanilla rockets are 1, some modded rockets hold many)
    launcher_data.ammo[ammo_name] = { atomic = atomic, magazine = ammo.magazine_size or 1 }

    for quality_name, level in pairs(qualities) do
      local variant = table.deepcopy(base)
      variant.name = NAME .. "-" .. ammo_name .. "-" .. quality_name
      variant.localised_name = {
        "", { "equipment-name." .. NAME }, " (", ammo.localised_name or { "item-name." .. ammo_name }, ")",
      }
      variant.localised_description = { "item-description." .. NAME }
      variant.take_result = NAME
      variant.hidden = true
      variant.attack_parameters.ammo_type = launcher_ammo_type(ammo)
      -- Use the ammo's own category so its damage and shooting speed research apply
      variant.attack_parameters.ammo_category = category
      -- Quality adds range by itself; this adds the damage (+30% per level, like quality ammo)
      variant.attack_parameters.damage_modifier = 1 + 0.3 * level
      if atomic then
        variant.attack_parameters.min_range = atomic_min_range
        variant.attack_parameters.range = math.max(range, atomic_min_range + 10)
      end
      local icon_layer = ammo_icon_layer(ammo)
      if icon_layer then
        variant.sprite = { layers = { table.deepcopy(base.sprite), icon_layer } }
      end
      data:extend({ variant })
      launcher_data.variants[variant.name] = { ammo = ammo_name, quality = quality_name }
    end
  end
end

-- The plain launcher means "not loaded" (just placed, out of rockets, or
-- toggled off): show it dimmed with the game's red no-ammo icon on top.
-- Done after the copies above so their sprites keep the normal look.
local utility = data.raw["utility-sprites"] and data.raw["utility-sprites"]["default"]
local no_ammo = utility and utility.ammo_icon and table.deepcopy(utility.ammo_icon)
local dimmed = table.deepcopy(base.sprite)
dimmed.tint = { r = 0.55, g = 0.55, b = 0.55, a = 1 }
if no_ammo and no_ammo.filename then
  local size = no_ammo.width or no_ammo.size or 64
  if type(size) == "table" then size = size[1] end
  no_ammo.scale = 96 / size -- half the 192px launcher
  no_ammo.shift = nil
  no_ammo.priority = "medium"
  base.sprite = { layers = { dimmed, no_ammo } }
else
  base.sprite = dimmed
end

data:extend({ { type = "mod-data", name = "prl-launcher-data", data = launcher_data } })
