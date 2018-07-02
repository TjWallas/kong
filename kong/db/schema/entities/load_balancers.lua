local Schema = require "kong.db.schema"
local typedefs = require "kong.db.schema.typedefs"
local utils = require "kong.tools.utils"


local validate_name = function(name)
  local p = utils.normalize_ip(name)
  if not p then
    return nil, "Invalid name; must be a valid hostname"
  end
  if p.type ~= "name" then
    return nil, "Invalid name; no ip addresses allowed"
  end
  if p.port then
    return nil, "Invalid name; no port allowed"
  end
  return true
end


local hash_on = Schema.define {
  type = "string",
  default = "none",
  one_of = { "none", "consumer", "ip", "header", "cookie" }
}


local http_statuses = Schema.define {
  type = "array",
  elements = { type = "integer", between = { 100, 999 }, },
}


local seconds = Schema.define {
  type = "integer",
  between = { 0, 65535 },
}


local positive_int = Schema.define {
  type = "integer",
  between = { 1, 2 ^ 31 },
}


local positive_int_or_zero = Schema.define {
  type = "integer",
  between = { 0, 2 ^ 31 },
}


local healthchecks_defaults = {
  active = {
    timeout = 1,
    concurrency = 10,
    http_path = "/",
    healthy = {
      interval = 0,  -- 0 = probing disabled by default
      http_statuses = { 200, 302 },
      successes = 0, -- 0 = disabled by default
    },
    unhealthy = {
      interval = 0, -- 0 = probing disabled by default
      http_statuses = { 429, 404,
                        500, 501, 502, 503, 504, 505 },
      tcp_failures = 0,  -- 0 = disabled by default
      timeouts = 0,      -- 0 = disabled by default
      http_failures = 0, -- 0 = disabled by default
    },
  },
  passive = {
    healthy = {
      http_statuses = { 200, 201, 202, 203, 204, 205, 206, 207, 208, 226,
                        300, 301, 302, 303, 304, 305, 306, 307, 308 },
      successes = 0,
    },
    unhealthy = {
      http_statuses = { 429, 500, 503 },
      tcp_failures = 0,  -- 0 = circuit-breaker disabled by default
      timeouts = 0,      -- 0 = circuit-breaker disabled by default
      http_failures = 0, -- 0 = circuit-breaker disabled by default
    },
  },
}


-- hcd("passive.unhealthy.timeouts") returns 0
local function hcd(route)
  local node = healthchecks_defaults
  for token in string.gmatch(route, "([^%.]+)") do
    node = assert(node[token], route)
  end
  return node
end


return {
  name = "load_balancers",
  primary_key = { "id" },
  fields = {
    { id = typedefs.uuid, },
    { created_at = { type = "integer", timestamp = true, auto = true }, },
    { name = { type = "string", required = true, custom_validator = validate_name }, },
    { hash_on = hash_on },
    { hash_fallback = hash_on },
    { hash_on_header = { type = "string" }, },
    { hash_fallback_header = { type = "string" }, },
    { hash_on_cookie = { type = "string",  custom_validator = utils.validate_cookie_name }, },
    { hash_on_cookie_path = typedefs.path{ default = "/", }, },
    { slots = { type = "integer", default = 10000, between = { 10, 2^16 }, }, },
    { healthchecks = { type = "record", default = healthchecks_defaults, fields = {

      { active = { type = "record", default = hcd("active"), fields = {

        { timeout = seconds{ default = hcd("active.timeout") }, },
        { concurrency = positive_int{ default = hcd("active.concurrency") }, },
        { http_path = typedefs.path{ default = hcd("active.http_path") }, },

        { healthy = { type = "record", default = hcd("active.healthy"), fields = {
          { interval = seconds{ default = hcd("active.healthy.interval") }, },
          { successes = positive_int_or_zero{ default = hcd("active.healthy.successes") }, },
          { http_statuses = http_statuses{ default = hcd("active.healthy.http_statuses"), }, },
        }, }, }, --/healthy

        { unhealthy = { type = "record", default = hcd("active.unhealthy"), fields = {
          { interval = seconds{ default = hcd("active.unhealthy.interval") }, },
          { http_statuses = http_statuses{ default = hcd("active.unhealthy.http_statuses"), }, },
          { tcp_failures = positive_int_or_zero{ default = hcd("active.unhealthy.tcp_failures") }, },
          { timeouts = positive_int_or_zero{ default = hcd("active.unhealthy.timeouts") }, },
          { http_failures = positive_int_or_zero{ default = hcd("active.unhealthy.http_failures") }, },
        }, }, }, -- /unhealthy
      }, }, }, -- /active

      { passive = { type = "record", defaults = hcd("passive"), fields = {

        { healthy = { type = "record", defaults = hcd("passive.healthy"), fields = {
          { http_statuses = http_statuses{ default = hcd("passive.healthy.http_statuses") }, },
          { successes = positive_int_or_zero{ default = hcd("passive.healthy.successes") }, },
        }, }, }, -- /healthy

        { unhealthy = { type = "record", defaults = hcd("passive.unhealthy"), fields = {
          { http_statuses = http_statuses{ default = hcd("passive.unhealthy.http_statuses"), }, },
          { tcp_failures = positive_int_or_zero{ default = hcd("passive.unhealthy.tcp_failures") }, },
          { timeouts = positive_int_or_zero{ default = hcd("passive.unhealthy.timeouts") }, },
          { http_failures = positive_int_or_zero{ default = hcd("passive.unhealthy.http_failures") }, },
        }, }, },
      }, }, }, -- /passive
    }, }, }, -- /healthchecks
  },
  entity_checks = {
    -- hash_on_header must be present when hashing on header
    { conditional = {
      if_field = "hash_on", if_match = { match = "^header$" },
      then_field = "hash_on_header", then_match = { required = true },
    }, },
    { conditional = {
      if_field = "hash_fallback", if_match = { match = "^header$" },
      then_field = "hash_fallback_header", then_match = { required = true },
    }, },

    -- hash_on_cookie must be present when hashing on cookie
    { conditional = {
      if_field = "hash_on", if_match = { match = "^cookie$" },
      then_field = "hash_on_cookie", then_match = { required = true },
    }, },
    { conditional = {
      if_field = "hash_fallback", if_match = { match = "^cookie$" },
      then_field = "hash_on_cookie", then_match = { required = true },
    }, },

    -- hash_fallback must be "none" if hash_on is "none"
    { conditional = {
      if_field = "hash_on", if_match = { match = "^none$" },
      then_field = "hash_fallback", then_match = { one_of = { "none" }, },
    }, },

    -- when hashing on cookies, hash_fallback is ignored
    { conditional = {
      if_field = "hash_on", if_match = { match = "^cookie$" },
      then_field = "hash_fallback", then_match = { one_of = { "none" }, },
    }, },

    -- hash_fallback must not equal hash_on (headers are allowed)
    { conditional = {
      if_field = "hash_on", if_match = { match = "^consumer$" },
      then_field = "hash_fallback", then_match = { one_of = { "none", "ip", "header", "cookie" }, },
    }, },
    { conditional = {
      if_field = "hash_on", if_match = { match = "^ip$" },
      then_field = "hash_fallback", then_match = { one_of = { "none", "consumer", "header", "cookie" }, },
    }, },
    -- TODO: check that upper(hash_on_header) ~= upper(hash_fallback_header)
  },
}
