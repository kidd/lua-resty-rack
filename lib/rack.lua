local rack = {}

rack._VERSION = '0.02'

local function process_rack_use_args(args)
  local route = table.remove(args, 1)
  local mw, options
  if type(route) == "table" or type(route) == "function" then
    mw = route
    route = nil
  else
    mw = table.remove(args, 1)
  end
  options = table.remove(args, 1) or {}
  return route, mw, options
end

local function get_ngx_middlewares()
  ngx.ctx.rack             = ngx.ctx.rack or {}
  ngx.ctx.rack.middlewares = ngx.ctx.rack.middlewares or {}
  return ngx.ctx.rack.middlewares
end

-- uri_relative = /test?arg=true
function get_ngx_uri_relative(query)
  return ngx.var.uri .. ngx.var.is_args .. query
end

-- uri_full = http://example.com/test?arg=true
function get_ngx_uri_full(uri_relative)
  return ngx.var.scheme .. '://' .. ngx.var.host .. uri_relative
end

local function get_middleware_function(mw, options)
  -- If we simply have a function, we can add that instead
  if type(mw) == "function" then return mw end
  -- If we have a 'call' function, then calling it with options should return a new function with the required params
  if type(mw) == "table" and type(mw.call) == "function" then return mw.call(options) end
  return nil
end

local function handle_ngx_response_errors(status, body)
  assert(status, "Middleware returned with no status. Perhaps you need to call next().")

  -- If we have a 5xx or a 3/4xx and no body entity, exit allowing nginx config
  -- to generate a response.
  if status >= 500 or (status >= 300 and body == nil) then
    ngx.exit(status)
  end
end

-- Runs the next middleware in the rack.
local function next_middleware()
  -- Pick each piece of middleware off in order
  local mwf = table.remove(ngx.ctx.rack.middlewares, 1)

  local req = ngx.ctx.rack.req
  local res = ngx.ctx.rack.res

  -- Call the middleware, which may itself call next().
  -- The first to return is handling the reponse.
  local post_function = mwf(req, res, next_middleware)

  if not ngx.headers_sent then
    handle_ngx_response_errors(res.status, res.body)

    for k,v in pairs(res.header) do ngx.header[k] = v end
    ngx.status = res.status
    ngx.print(res.body)
    ngx.eof()
  end

  -- Middleware may return a callable object to be called post-EOF.
  -- This code will only run for persistent connections, and is not really guaranteed
  -- to run, since browser behaviours differ. Also be aware that long running tasks
  -- may affect performance by hogging the connection.
  if post_function then post_function(req, res) end
end

-- Register some middleware to be used.
--
-- @param   string  route       Optional, dfaults to '/'.
-- @param   table   middleware  The middleware module
-- @param   table   options     Table of options for the middleware.
-- @return  void
function rack.use(...)
  local route, mw, options = process_rack_use_args({...})

  if route and string.sub(ngx.var.uri, 1, route:len()) ~= route then return false end

  local mwf = get_middleware_function(mw, options)
  if not mwf then return nil, "Invalid middleware" end

  local middlewares = get_ngx_middlewares()
  table.insert(middlewares, mwf)
  return true
end

-- Start the rack.
function rack.run()
  -- We need a decent req / res environment to pass around middleware.
  if not ngx.ctx.rack or not ngx.ctx.rack.middlewares then
    ngx.log(ngx.ERR, "Attempted to run rack without any middleware.")
    return
  end

  local query         = ngx.var.query_string or ""
  local uri_relative  = get_ngx_uri_relative(query)
  local uri_full      = get_ngx_uri_full(uri_relative)
  local req_fallback  = function(k) return ngx.var["http_" .. k] end

  ngx.ctx.rack.req = {
    body          = "",
    query         = query,
    uri_full      = uri_full,
    uri_relative  = uri_relative,
    method        = ngx.var.request_method,
    args          = ngx.req.get_uri_args(),
    scheme        = ngx.var.scheme,
    uri           = ngx.var.uri,
    host          = ngx.var.host,
    header = {}
  }
  ngx.ctx.rack.res = {
    header = {},
    status = nil,
    body = nil
  }

  -- uri_relative = /test?arg=true
  ngx.ctx.rack.req.uri_relative = ngx.var.uri .. ngx.var.is_args .. ngx.ctx.rack.req.query

  -- uri_full = http://example.com/test?arg=true
  ngx.ctx.rack.req.uri_full = ngx.var.scheme .. '://' .. ngx.var.host .. ngx.ctx.rack.req.uri_relative


  -- Case insensitive request and response headers.
  --
  -- ngx_lua has request headers available case insensitively with ngx.var.http_*, but
  -- these cannot be iternated over or added to (for fake request headers).
  --
  -- Response headers are set to ngx.header.*, and can also be set and read case
  -- insensitively, but they cannot be iterated over.
  --
  -- Ideally, we should be able to set/get headers in req.header and res.header case
  -- insensitively, with optional underscores instead of dashes (for consistency), and
  -- iterate over them (with the case they were set).


  -- For request headers, we must:
  -- * Keep track of fake request headers in a normalised (lowercased / underscored) state.
  -- * First try a direct hit, then fall back to the normalised table, and ngx.var.http_*
  local req_h_mt = {
    normalised = {}
  }

  req_h_mt.__index = function(t, k)
    k = k:lower():gsub("-", "_")
    return req_h_mt.normalised[k] or ngx.var["http_" .. k]
  end

  req_h_mt.__newindex = function(t, k, v)
    rawset(t, k, v)

    k = k:lower():gsub("-", "_")
    req_h_mt.normalised[k] = v
  end

  setmetatable(ngx.ctx.rack.req.header, req_h_mt)


  -- For response headers, we simply keep things proxied and normalised, to be set
  -- to ngx.header.* later.
  local res_h_mt = {
    normalised = {}
  }

  res_h_mt.__index = function(t, k)
    k = k:lower():gsub("-", "_")
    return res_h_mt.normalised[k]
  end

  res_h_mt.__newindex = function(t, k, v)
    rawset(t, k, v)
    k = k:lower():gsub("-", "_")
    res_h_mt.normalised[k] = v
  end

  setmetatable(ngx.ctx.rack.res.header, res_h_mt)

  next_middleware()
end

-- to prevent use of casual module global variables
setmetatable(rack,{
  __newindex = function (table, key, val)
    error('attempt to write to undeclared variable "' .. key .. '": ' .. debug.traceback())
  end})


  return rack
