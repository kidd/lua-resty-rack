-- this intermediate middleware reads the request body (a potentially costly operation in nginx) and stores it
-- inside req.body, for future usage in other middlewares.
local read_body = {
  _VERSION  = '0.01',
  call      = function(options)
    return function(req, res, next_middleware)
      ngx.req.read_body()
      req.body = ngx.req.get_body_data()
      next_middleware()
    end
  end
}

return read_body

