local method_override = {
  _VERSION = '0.01',
  call     = function(options)
    return function(req, res, next_middleware)
      local key = options['key'] or '_method'
      req.method = string.upper(req.args[key] or req.method)
      next_middleware()
    end
  end
}

return method_override

