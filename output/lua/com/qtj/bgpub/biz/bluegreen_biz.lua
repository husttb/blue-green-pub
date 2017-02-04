-- 蓝绿发布 BIZ 层.
--
-- Author: qintianjie
-- Date:   2017-01-05

local modulename = "biz.bluegreen"
local _M = {}
_M._VERSION = '1.0.0'

local redis_biz 	 = require("biz.redis_biz")
local error_code     = require('utils.error_code').info

local upstream 		   = require ("ngx.upstream")
local string_utils     = require ("utils.string_utils")

-- 配置信息
local config_base 	= require("configbase")
local switch_key    = config_base.fields["switch"]
local optype_key    = config_base.fields["optype"]
local opdata_key    = config_base.fields["opdata"]
local ups_group     = config_base.ups_group

local collection_utils = require ("utils.collection_utils")

-- 规则缓存在 nginx dict 名
local rule_data_cache = ngx.shared["dict_rule_data"]

-- 根据传入的 service_name ，从 redis 取相关规则数据，设置到 shared dict 中
-- conf = {["s_key":xxx]} : s_key ==> 传入的服务名，可以逗号分隔为多个
_M.ruleset = function (conf)
	local service_keys = conf.s_key
	local red, err = redis_biz.redisconn()
	if not red then
		local info = error_code.REDIS_CONNECT_ERROR 
	    local desc = "Redis connect error [" .. cjson.encode(redisConf) .. "]" 
	    ngx.log(ngx.ERR, '[BIZ] code: "', info[1], '". RedisConf: [' , cjson.encode(redisConf),  '] ', err)
    	return info[1], desc
	else
		local redis = red.redis 
	    local service_key_arr = string_utils.split(service_keys, ",")
	    local info = error_code.SUCCESS 
	    local data = {}
	    for i in pairs(service_key_arr) do
	        local s_key = service_key_arr[i]
	        if s_key ~= nil and string.len(s_key) > 0 then
	          local real_key = string_utils.trim(s_key)
	          -- 构造 redis key:   policyPrefix:servicename 格式
	          local service_key = table.concat({config_base.prefixConf["policyPrefix"],real_key},":")

	          -- 每个 key 都是一个 map， 对应规则数据有:  switch 路由, optype 操作类型, opdata: 操作数据
	          local switch = redis:hget(service_key, switch_key)
	          local optype = redis:hget(service_key, optype_key)
	          local opdata = redis:hget(service_key, opdata_key)

	          data[s_key .. "." .. switch_key] = switch
	          data[s_key .. "." .. optype_key] = optype
	          data[s_key .. "." .. opdata_key] = opdata

	          -- 验证数据有效性， 这里不直接 return 是考虑更新多个服务的时，前面服务的数据不全，不影响后面服务继续面服务的数据不全，不影响后面服务继续
	      	  if switch== ngx.null or switch == "" or optype == ngx.null or optype == "" or opdata == ngx.null or opdata == "" then
	      	  	info = error_code.POLICY_INVALID_ERROR
	      	  	ngx.log(ngx.ERR, string.format("[API] [%d] %s[%s]", info[1], info[2], service_key))	
	            -- ngx.log(ngx.ERR, "policy or policy item is null when set [" .. service_key .. "].")	  
	      	    
	      	    data[s_key .. ".result"] = "data_error"
	      	  else
	      	  	-- 将 redis 得到的数据，存入 ngx.shared.dict 中
	          	rule_data_cache:set(service_key .. ":" .. switch_key, switch)
	          	rule_data_cache:set(service_key .. ":" .. optype_key, optype)
	          	rule_data_cache:set(service_key .. ":" .. opdata_key, opdata)
	          	data[s_key .. ".result"] = "succeed"
	      	  end
	        end
	    end

	    -- if red then
	    -- 	local temp_t = {["k1"]="v1", ["grayType"]="unamein"}
	    -- 	local redis = red.redis 
	    -- 	-- red:hmset("bizgray:gray:apollo", "temp", temp)
	    -- 	-- local res, err = redis:hmset("biztech:gray:apollo", "switch", nil, "grayType", "uidmod")
	    -- 	-- HMSET biztech:gray:apollo graySwitch true grayType in grayData 111,222,333

	    -- 	local res, err = redis:hmset("biztech:gray:apollo", "abc", cjson.encode(temp_t))
	    -- 	local bb, err = redis:hget("biztech:gray:apollo", "abc")
	    -- 	local t_001 = cjson.decode(bb)
	    -- 	t_001["k1"] = "abcdkkkk"
	    -- 	redis:hmset("biztech:gray:apollo", "abc", cjson.encode(t_001))

	    -- 	redis:hdel("biztech:gray:apollo", "switch")
	    -- 	ngx.say("====> bb: " .. t_001["k1"])
	    -- end

	    -- will close current redis connect
	    if red then redis_biz.setKeepalive(red) end
	    return info[1], data
	end

	return nil, ""
end

-- get ruledata from ngx.shared.dict
_M.ruleget = function (conf)
	local service_name = conf.s_key
	-- local rule_data_cache = ngx.shared["dict_rule_data"]
	local result = {}

	if service_name and string.len(service_name) > 0 then
        local key_prefix   = config_base.prefixConf["policyPrefix"]

        local buffer_switch_key = table.concat({key_prefix, service_name, switch_key}, ":")
        local buffer_optype_key = table.concat({key_prefix, service_name, optype_key}, ":")
        local buffer_opdata_key = table.concat({key_prefix, service_name, opdata_key}, ":")

        
        result["service_name"] = service_name
        result["cache.prifix"] = key_prefix .. ":" .. service_name

        local data = {}
        data[switch_key] = rule_data_cache:get(buffer_switch_key)
        data[optype_key] = rule_data_cache:get(buffer_optype_key)
        data[opdata_key] = rule_data_cache:get(buffer_opdata_key)

        result["data"] = data
	else
		result["service_name"] = "ALL"
        result["cache.prifix"] = "ALL limit 1000"

        local switch_keys = rule_data_cache:get_keys(100)  
        local data = {} 
        for k, v in ipairs(switch_keys) do       
            data[v] = rule_data_cache:get(v)
        end

        result["data"] = data
	end

	return result
end

-- delete ruledata from ngx.shared.dict
-- NOTE: make sure delete data from redis by manual
_M.ruledelete = function (conf)
	local service_keys = conf.s_key
	local service_key_arr = string_utils.split(service_keys, ",")
	for i in pairs(service_key_arr) do
        local s_key = service_key_arr[i]
        if s_key ~= nil and string.len(s_key) > 0 then
          	local real_key = string_utils.trim(s_key)
          	-- 构造 redis key:   policyPrefix:servicename 格式
          	local service_key = table.concat({config_base.prefixConf["policyPrefix"],real_key},":")

			rule_data_cache:set(service_key .. ":" .. switch_key, nil)
			rule_data_cache:set(service_key .. ":" .. optype_key, nil)
			rule_data_cache:set(service_key .. ":" .. opdata_key, nil)
		end
	end
	return "ok", "succeed deleted"
end

-- update switch ruledata from ngx.shared.dict
-- NOTE: make sure delete data from redis by manual
_M.switchupdate = function (conf)
	local switch_value = conf.switch_value
	local service_keys = conf.s_key
	local service_key_arr = string_utils.split(service_keys, ",")
	for i in pairs(service_key_arr) do
        local s_key = service_key_arr[i]
        if s_key ~= nil and string.len(s_key) > 0 then
          	local real_key = string_utils.trim(s_key)
          	-- 构造 redis key:   policyPrefix:servicename 格式
          	local service_key = table.concat({config_base.prefixConf["policyPrefix"],real_key},":")
			rule_data_cache:set(service_key .. ":" .. switch_key, switch_value)
		end
	end
	return "0", "succeed update switch value"
end

local sync_redis_to_dict = function ( )
	ngx.log(ngx.ERR, "=====> init work for work 0")
	local concat = table.concat
    local upstream = require "ngx.upstream"
    local get_servers = upstream.get_servers
    local get_upstreams = upstream.get_upstreams
    
    local us = get_upstreams()
    if us ~= nil then
    	local red, err = redis_biz.redisconn()
		if not red then
			local info = error_code.REDIS_CONNECT_ERROR 
		    local desc = "Redis connect error [" .. cjson.encode(redisConf) .. "]" 
		    ngx.log(ngx.ERR, '[BIZ] code: "', info[1], '". RedisConf: [' , cjson.encode(redisConf),  '] ', err)
	    	return 
		else
			local redis = red.redis 

			local keyDict = {}
	        for _, u in ipairs(us) do
	        	-- ngx.log(ngx.ERR, "------> ups: " .. u)

	        	repeat
	        		local last_index = string_utils:last_indexof(u, "_")
		        	if last_index == nil or last_index < 1 then
		        		break
		        	end

		        	local ups_sufix = string.sub(u, 1, last_index - 1)
		        	if keyDict[ups_sufix] ~= nil then
		        		break
		        	else
		        		keyDict[ups_sufix] = "true"
		        	end
		        	-- ngx.log(ngx.ERR, "[service]------> service: " .. ups_sufix)
	          		-- 构造 redis key:   policyPrefix:servicename 格式
	          		local service_key = table.concat({config_base.prefixConf["policyPrefix"],ups_sufix},":")

	          		-- 每个 key 都是一个 map， 对应规则数据有:  switch 路由, optype 操作类型, opdata: 操作数据
	          		local switch = redis:hget(service_key, switch_key)
	          		local optype = redis:hget(service_key, optype_key)
	          		local opdata = redis:hget(service_key, opdata_key)

	          		for _, k in ipairs(ups_group) do
	          			local data_cache_ups_size_key = service_key .. ":_" .. k
	          			local group_content = redis:hget(service_key, "_" .. k)   -- _g1, _g2
	          			local upsSize = 0

	          			if group_content ~= nil and type(group_content) == "string" then
	          				local gcJson = cjson.decode(group_content)
	          				for k, v in pairs(gcJson) do
	          					if v ~=nil and type(v) == "string" then
	          						local downIndex = string.find(v, "down")
	          						if downIndex == nil then upsSize = upsSize + 1 end
	          					end
	          				end
	          				-- ngx.log(ngx.ERR, "---> k: " .. k)
	          			end
	          			-- ngx.log(ngx.ERR, "---> k: " .. data_cache_ups_size_key .. ", size: " .. upsSize)
	          			rule_data_cache:set(data_cache_ups_size_key, upsSize)
	          		end


	          		-- data[s_key .. "." .. switch_key] = switch
	          		-- data[s_key .. "." .. optype_key] = optype
	          		-- data[s_key .. "." .. opdata_key] = opdata

	          		-- 验证数据有效性， 这里不直接 return 是考虑更新多个服务的时，前面服务的数据不全，不影响后面服务继续面服务的数据不全，不影响后面服务继续
	      	  		if switch== ngx.null or switch == "" or optype == ngx.null or optype == "" or opdata == ngx.null or opdata == "" then
	      	  			info = error_code.POLICY_INVALID_ERROR
	      	  			ngx.log(ngx.ERR, string.format("[API] [%d] %s[%s]", info[1], info[2], service_key))	
	            		-- ngx.log(ngx.ERR, "policy or policy item is null when set [" .. service_key .. "].")	  
	      	    
	      	    		-- data[s_key .. ".result"] = "data_error"
	      	  		else
	      	  			-- 将 redis 得到的数据，存入 ngx.shared.dict 中
	          			rule_data_cache:set(service_key .. ":" .. switch_key, switch)
	          			rule_data_cache:set(service_key .. ":" .. optype_key, optype)
	          			rule_data_cache:set(service_key .. ":" .. opdata_key, opdata)
	          			-- data[s_key .. ".result"] = "succeed"
	      	  		end
	        	until true
	        end
	        keyDict = {}

	        if red then redis_biz.setKeepalive(red) end
	    end
    end
end

_M.init_worker = function (self) 
	local delay = 5  -- 5s
	local schedule_worker_after_start
	schedule_worker_after_start = function (premature)
	    if premature then
	        return
	    end
	    sync_redis_to_dict()
	    local ok, err = ngx.timer.at(delay, schedule_worker_after_start)
	    if not ok then
	        ngx.log(ngx.ERR, "failed to create the timer: ", err)
	        return
	    end
	end

	if ngx.worker.id() == 0 then
	 	ngx.timer.at(0, sync_redis_to_dict) 

	 	local ok, err = ngx.timer.at(delay, schedule_worker_after_start)
		if not ok then
		    ngx.log(ngx.ERR, "failed to create the timer: ", err)
		    return
		end
	end
end

return _M