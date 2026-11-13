data:extend({
  { type = "int-setting",    name = "prl-range",            setting_type = "startup", default_value = 30, minimum_value = 10, maximum_value = 60,  order = "a" },
  { type = "int-setting",    name = "prl-cooldown",         setting_type = "startup", default_value = 60, minimum_value = 6,  maximum_value = 600, order = "b" },
  { type = "int-setting",    name = "prl-atomic-min-range", setting_type = "startup", default_value = 30, minimum_value = 0,  maximum_value = 100, order = "c" },
  { type = "int-setting",    name = "prl-check-interval",   setting_type = "runtime-global", default_value = 10, minimum_value = 1, maximum_value = 60, order = "a" },
  { type = "bool-setting",   name = "prl-allow-atomic",     setting_type = "runtime-per-user", default_value = false, order = "a" },
  { type = "string-setting", name = "prl-ammo-priority",    setting_type = "runtime-per-user", default_value = "atomic-bomb, explosive-rocket, rocket", allow_blank = true, order = "b" },
})
