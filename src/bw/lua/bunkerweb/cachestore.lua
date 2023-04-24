local mlcache		= require "resty.mlcache"
local logger		= require "bunkerweb.logger"
local class     	= require "middleclass"
local cachestore	= class("cachestore")

-- Instantiate mlcache object at module level (which will be cached when running init phase)
-- TODO : custom settings
local shm		= "cachestore"
local ipc_shm	= "cachestore_ipc"
local shm_miss	= "cachestore_miss"
local shm_locks	= "cachestore_locks"
if not ngx.shared.cachestore then
	shm			= "cachestore_stream"
	ipc_shm		= "cachestore_ipc_stream"
	shm_miss	= "cachestore_miss_stream"
	shm_locks	= "cachestore_locks_stream"
end
local cache, err = mlcache.new(
	"cachestore",
	shm,
	{
		lru_size = 100,
		ttl = 30,
		neg_ttl = 0.1,
		shm_set_tries = 3,
		shm_miss = shm_miss,
		shm_locks = shm_locks,
		resty_lock_opts = {
			exptime = 30,
			timeout = 5,
			step = 0.001,
			ratio = 2,
			max_step = 0.5
		},
		ipc_shm = ipc_shm
	}
)
local module_logger = logger:new("CACHESTORE")
if not cache then
	module_logger:log(ngx.ERR, "can't instantiate mlcache : " .. err)
end

function cachestore:initialize(use_redis)
	self.cache = cache
	self.use_redis = use_redis or false
	self.logger = module_logger
end

function cachestore:get(key)
	local callback = function(key)
		-- Connect to redis
		local clusterstore = require "bunkerweb.clusterstore":new()
		local ok, err = clusterstore:connect()
		if not ok then
			return nil, "can't connect to redis : " .. err, nil
		end
		-- Redis script to get value + ttl
		local redis_script = [[
			local ret_get = redis.pcall("GET", KEYS[1])
			if type(ret_get) == "table" and ret_get["err"] ~= nil then
				redis.log(redis.LOG_WARNING, "BUNKERWEB CACHESTORE GET error : " .. ret_get["err"])
				return ret_get
			end
			local ret_ttl = redis.pcall("TTL", KEYS[1])
			if type(ret_ttl) == "table" and ret_ttl["err"] ~= nil then
				redis.log(redis.LOG_WARNING, "BUNKERWEB CACHESTORE DEL error : " .. ret_ttl["err"])
				return ret_ttl
			end
			return {ret_get, ret_ttl}
		]]
		local ret, err = clusterstore:call("eval", redis_script, 1, key)
		if not ret then
			clusterstore:close()
			return nil, err, nil
		end
		-- Extract values
		clusterstore:close()
		if ret[1] == ngx.null then
			ret[1] = nil
		end
		if ret[2] < 0 then
			ret[2] = ret[2] + 1
		end
		return ret[1], nil, ret[2]
	end
	local value, err, hit_level
	if self.use_redis then
		value, err, hit_level = self.cache:get(key, nil, callback, key)
	else
		value, err, hit_level = self.cache:get(key)
	end
	if value == nil and err ~= nil then
		return false, err
	end
	self.logger:log(ngx.INFO, "hit level for " .. key .. " = " .. tostring(hit_level))
	return true, value
end

function cachestore:set(key, value, ex)
	if self.use_redis then
		local ok, err = self.set_redis(key, value, ex)
		if not ok then
			self.logger:log(ngx.ERR, err)
		end
	end
	local ok, err
	if ex then
		ok, err = self.cache:set(key, {ttl = ex}, value)
	else
		ok, err = self.cache:set(key, nil, value)
	end
	if not ok then
		return false, err
	end
	return true
end

function cachestore:set_redis(key, value, ex)
	-- Connect to redis
	local clusterstore = require "bunkerweb.clusterstore":new()
	local ok, err = clusterstore:connect()
	if not ok then
		return false, "can't connect to redis : " .. err
	end
	-- Set value with ttl
	local default_ex = ex or 30
	local ok, err = clusterstore:call("set", key, value, "EX", default_ex)
	if err then
		clusterstore:close()
		return false, "SET failed : " .. err
	end
	clusterstore:close()
	return true
end

function cachestore:delete(key, value, ex)
	if self.use_redis then
		local ok, err = self.del_redis(key)
		if not ok then
			self.logger:log(ngx.ERR, err)
		end
	end
	local ok, err = self.cache:delete(key)
	if not ok then
		return false, err
	end
	return true
end

function cachestore:del_redis(key)
	-- Connect to redis
	local clusterstore = require "bunkerweb.clusterstore":new()
	local ok, err = clusterstore:connect()
	if not ok then
		return false, "can't connect to redis : " .. err
	end
	-- Set value with ttl
	local ok, err = clusterstore:del(key)
	if err then
		clusterstore:close()
		return false, "DEL failed : " .. err
	end
	clusterstore:close()
	return true
end

return cachestore
