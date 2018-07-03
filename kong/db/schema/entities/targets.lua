local typedefs = require "kong.db.schema.typedefs"

return {
  name = "targets",
  primary_key = { "id" },
  fields = {
    { id = typedefs.uuid },
    { created_at = { type = "integer", timestamp = true, auto = true }, },
    { balancer   = { type = "foreign", reference = "balancers", required = true }, },
-- FIXME: need to use utils.format_host to transform the target
    { target     = typedefs.host { required = true }, },
    { weight     = { type = "integer", default = 100, between = { 0, 1000 }, }, },
  },
}
