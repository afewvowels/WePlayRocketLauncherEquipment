local NAME = "wp-personal-rocket-launcher-equipment"
local launcher = data.raw.gun["rocket-launcher"]

data:extend({
  {
    type = "active-defense-equipment",
    name = NAME,
    sprite = {
      filename = "__WePlayRocketLauncherEquipment__/graphics/personal-rocket-launcher-equipment.png",
      width = 192,
      height = 192,
      priority = "medium",
    },
    shape = { width = 3, height = 3, type = "full" },
    categories = { "armor" },
    energy_source = {
      type = "electric",
      usage_priority = "secondary-input",
      -- The buffer IS the loaded rocket: control.lua sets it to 1J when it
      -- takes a rocket from the inventory, and each shot uses that 1J.
      -- It never charges from the armor grid.
      buffer_capacity = "1J",
      input_flow_limit = "0W",
    },
    automatic = true,
    attack_parameters = {
      type = "projectile",
      ammo_category = "rocket",
      cooldown = settings.startup["prl-cooldown"].value,
      range = settings.startup["prl-range"].value,
      projectile_creation_distance = 0.6,
      sound = launcher and table.deepcopy(launcher.attack_parameters.sound) or nil,
      -- ammo_type is filled in data-final-fixes.lua from the (possibly modded) rocket
      ammo_type = {},
    },
  },
  {
    type = "item",
    name = NAME,
    icon = "__WePlayRocketLauncherEquipment__/graphics/personal-rocket-launcher-icon.png",
    icon_size = 64,
    mipmap_count = 4,
    place_as_equipment_result = NAME,
    subgroup = "military-equipment",
    order = "d[active-defense]-c[personal-rocket-launcher]",
    stack_size = 20,
  },
  {
    type = "recipe",
    name = NAME,
    enabled = false,
    energy_required = 10,
    ingredients = {
      { type = "item", name = "rocket-launcher", amount = 1 },
      { type = "item", name = "advanced-circuit", amount = 10 },
      { type = "item", name = "steel-plate", amount = 10 },
    },
    results = { { type = "item", name = NAME, amount = 1 } },
  },
  {
    type = "custom-input",
    name = "prl-toggle",
    key_sequence = "CONTROL + ALT + R",
    consuming = "none",
  },
})

local tech = data.raw.technology["rocketry"]
if tech then
  tech.effects = tech.effects or {}
  table.insert(tech.effects, { type = "unlock-recipe", recipe = NAME })
else
  data.raw.recipe[NAME].enabled = true
end
