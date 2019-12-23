local require = require
local luaObjectInfo = require("__debugadapter__/luaobjectinfo.lua")
local normalizeLuaSource = require("__debugadapter__/normalizeLuaSource.lua")
local json = require("__debugadapter__/json.lua")

local __DebugAdapter = __DebugAdapter
local debug = debug
local table = table
local setmetatable = setmetatable
local next = next
local pairs = pairs
local print = print
local pcall = pcall
local type = type

-- Trying to expand the refs table causes some problems, so just hide it...
local refsmeta = {
  __debugline = "<Debug Adapter Variable ID Cache [{#self}]>",
  __debugchildren = false,
}

--- Debug Adapter variables module
local variables = {
  refs = setmetatable({},refsmeta),
}


local gmeta = getmetatable(_ENV)
if not gmeta then
  gmeta = {}
  setmetatable(_ENV,gmeta)
end
local globalbuiltins={
  _G = "builtin", assert = "builtin", collectgarbage = "builtin", error = "builtin", getmetatable = "builtin",
  ipairs = "builtin", load = "builtin", loadstring = "builtin", next = "builtin", pairs = "builtin", pcall = "builtin",
  print = "builtin", rawequal = "builtin", rawlen = "builtin", rawget = "builtin", rawset = "builtin", select = "builtin",
  setmetatable = "builtin", tonumber = "builtin", tostring = "builtin", type = "builtin", xpcall = "builtin", _VERSION = "builtin",
  unpack = "builtin", table = "builtin", string = "builtin", bit32 = "builtin", math = "builtin", debug = "builtin", serpent = "builtin",
  log = "builtin", table_size = "builtin", package = "builtin", require = "builtin",

  remote = "factorio", commands = "factorio", settings = "factorio", rcon = "factorio", rendering = "factorio",
  script = "factorio", defines = "factorio", game = "factorio", global = "factorio"
}
gmeta.__debugline = "<Global Self Reference>"
gmeta.__debugchildren = function(t,extra)
  local vars = {}
  if not extra then
    vars[#vars + 1] =  {
      name = "<Lua Builtin Globals>",
      value = "<Lua Builtin Globals>",
      type = "<Lua Builtin Globals>",
      variablesReference = variables.tableRef(t,nil,false,"builtin"),
    }
    vars[#vars + 1] =  {
      name = "<Factorio API>",
      value = "<Factorio API>",
      type = "<Factorio API>",
      variablesReference = variables.tableRef(t,nil,false,"factorio"),
    }

  end
  for k,v in pairs(t) do
    if globalbuiltins[k] == extra then -- nil for top level, true for "show hidden"
      vars[#vars + 1] = variables.create(variables.describe(k,true),v)
    end
  end
  return vars
end

--- Clear all existing variable references, when stepping invalidates them
function variables.clear()
  variables.refs = setmetatable({},refsmeta)
end

--- Generate a variablesReference for `name` at frame `frameId`
---@param frameId number
---@param name string
---@param mode string|nil "temps" | "vararg"
---@return number variablesReference
function variables.scopeRef(frameId,name,mode)
  for id,varRef in pairs(variables.refs) do
    if varRef.type == name and varRef.frameId == frameId and varRef.mode == mode then
      return id
    end
  end
  local id = #variables.refs+1
  variables.refs[id] = {
    type = name,
    frameId = frameId,
    mode = mode,
  }
  return id
end

--- Generate a variablesReference for a table-like object
---@param table table
---@param mode string "pairs"|"ipairs"|"count"
---@param showMeta nil | boolean
---@param extra any
---@return number variablesReference
function variables.tableRef(table, mode, showMeta, extra)
  for id,varRef in pairs(variables.refs) do
    if varRef.type == "Table" and varRef.table == table and (varRef.mode or "pairs") == mode and varRef.showMeta == showMeta then
      return id
    end
  end
  local id = #variables.refs+1
  variables.refs[id] = {
    type = "Table",
    table = table,
    mode = mode,
    showMeta = showMeta,
    extra = extra
  }
  return id
end

--- Generate a variablesReference for a LuaObject
---@param luaObject LuaObject
---@param classname string
---@return number variablesReference
function variables.luaObjectRef(luaObject,classname)
  if not luaObjectInfo.expandKeys[classname] then return 0 end
  for id,varRef in pairs(variables.refs) do
    if varRef.type == "LuaObject" and varRef.object == luaObject then return id end
  end
  local id = #variables.refs+1
  variables.refs[id] = {
    type = "LuaObject",
    object = luaObject,
    classname = classname,
  }
  return id
end

--- Generates a description for `value`.
--- Also returns data type as second return.
---@param value any
---@param short nil | boolean
---@return string lineitem
---@return string datatype
function variables.describe(value,short)
  local lineitem
  local vtype = type(value)
  if vtype == "table" then
    -- only check __self and metatable, since top level objects (game, script, etc) don't have the magic string in .isluaobject
    if type(value.__self) == "userdata" and getmetatable(value) == "private" then
      vtype = luaObjectInfo.classname(value)
      if vtype == "LuaCustomTable" then
          lineitem = ("%d item%s"):format(#value, #value~=1 and "s" or "" )
      else
        local lineitemfmt = luaObjectInfo.lineItem[vtype]
        lineitem = ("<%s>"):format(vtype)
        local litype = type(lineitemfmt)
        if litype == "function" then
          -- don't crash a debug session for a bad formatter...
          local success,result = pcall(lineitemfmt,value,short)
          if success then lineitem = result end
        elseif litype == "string" and not short then
          lineitem = __DebugAdapter.stringInterp(lineitemfmt,nil,value,"luaobjectline")
        end

      end
    else -- non-LuaObject tables
      local mt = debug.getmetatable(value)
      if mt and mt.__debugline then -- it knows how to make a line for itself...
        local debugline = mt.__debugline
        local dltype = type(debugline)
        if dltype == "function" then
          -- don't crash a debug session for a bad user-provided formatter...
          local success,result = pcall(debugline,value,short)
          if success then
            lineitem = result
          else
            lineitem = "<__debugline error>"
          end
        elseif dltype == "string" and not short then
          lineitem = __DebugAdapter.stringInterp(debugline,nil,value,"metadebugline")
        else
          lineitem = "{<...>}"
        end
      else
        if short then
          if next(value) or mt then
            -- this table has contents or other nontrivial behavior
            lineitem = "{<...>}"
          else
            -- this is an empty table!
            lineitem = "{}"
          end
        else
          -- generate { [shortdescribe(key)]=shortdescribe(value), ... }
          -- but omit consecutive numeric indexes { shortdescribe(value), ... }
          local inext = 1
          if next(value) then
            local innerpairs = { "{ " }
            for k,v in pairs(value) do
              if k == inext then
                innerpairs[#innerpairs + 1] = ([[%s, ]]):format(variables.describe(v,true))
                inext = inext + 1
              else
                inext = nil
                if type(k) == "string" and k:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
                  innerpairs[#innerpairs + 1] = ([[%s=%s, ]]):format(
                    k, variables.describe(v,true))
                else
                  innerpairs[#innerpairs + 1] = ([[[%s]=%s, ]]):format(
                    variables.describe(k,true), variables.describe(v,true))
                end

              end
            end
            innerpairs[#innerpairs + 1] = "}"
            lineitem = table.concat(innerpairs)
          else
            -- this is an empty table!
            lineitem = "{}"
          end
        end
      end
    end
  elseif vtype == "function" then
    local info = debug.getinfo(value, "nS")
    lineitem = "<function>"
    if not short then
      if info.what == "C" then
        lineitem = "<C function>"
      elseif info.what == "Lua" then
        lineitem = ("<Lua function @%s:%d>"):format(info.source and normalizeLuaSource(info.source),info.linedefined)
      elseif info.what == "main" then
        lineitem = ("<main chunk @%s>"):format(info.source and normalizeLuaSource(info.source))
      end
    end
  elseif vtype == "userdata" then
    lineitem = "<userdata>"
  elseif vtype == "string" then
    lineitem = ("%q"):format(value)
  else -- boolean, number, nil
    lineitem = tostring(value)
  end
  return lineitem,vtype
end

--- Generate a default debug view for `value` named `name`
---@param name string | nil
---@param value any
---@return Variable
function variables.create(name,value)
  local lineitem,vtype = variables.describe(value)
  local variablesReference = 0
  if vtype == "LuaCustomTable" then
    variablesReference = variables.tableRef(value,"pairs",false)
  elseif vtype:sub(1,3) == "Lua" then
    variablesReference = variables.luaObjectRef(value,vtype)
  elseif vtype == "table" then
    local mt = debug.getmetatable(value)
    if not mt or mt.__debugchildren ~= false then
      variablesReference = variables.tableRef(value)
    end
  end
    return {
      name = name,
      value = lineitem,
      type = vtype,
      variablesReference = variablesReference,
    }
end

local itermode = {
  pairs = pairs,
  ipairs = ipairs,
}

--- DebugAdapter VariablesRequest
---@param variablesReference integer
---@return Variable[]
function __DebugAdapter.variables(variablesReference)
  local varRef = variables.refs[variablesReference]
  local vars = {}
  if varRef then
    if varRef.type == "Locals" then
      local mode = varRef.mode
      local hasTemps =  false
      local i = 1
      while true do
        local name,value = debug.getlocal(varRef.frameId,i)
        if not name then break end
        local isTemp = name:sub(1,1) == "("
        if isTemp then hasTemps = true end
        if (mode == "temps" and isTemp) or (not mode and not isTemp) then
          if isTemp then
            name = ("%s %d)"):format(name:sub(1,-2),i)
          end
          vars[#vars + 1] = variables.create(name,value)
        end
        i = i + 1
      end
      if not mode and hasTemps then
        table.insert(vars,1,{ name = "<temporaries>", value = "<temporaries>", variablesReference = variables.scopeRef(varRef.frameId,"Locals","temps") })
      end

      if mode == "varargs" then
      i = -1
      while true do
        local name,value = debug.getlocal(varRef.frameId,i)
        if not name then break end
        vars[#vars + 1] = variables.create(("(*vararg %d)"):format(-i),value)
        i = i - 1
      end
      elseif not mode then
        local info = debug.getinfo(varRef.frameId,"u")
        if info.isvararg then
          local varargidx = info.nparams + 1
          if hasTemps then varargidx = varargidx + 1 end

          table.insert(vars,varargidx,{ name = "<varargs>", value = "<varargs>", variablesReference = variables.scopeRef(varRef.frameId,"Locals","varargs") })
        end
      end
    elseif varRef.type == "Upvalues" then
      local func = debug.getinfo(varRef.frameId,"f").func
      local i = 1
      while true do
        local name,value = debug.getupvalue(func,i)
        if not name then break end
        vars[#vars + 1] = variables.create(name,value)
        i = i + 1
      end
    elseif varRef.type == "Table" then
      -- use debug.getmetatable insead of getmetatable to get raw meta instead of __metatable result
      local mt = debug.getmetatable(varRef.table)
      if varRef.mode == "count" then
        --don't show meta on these by default as they're mostly LuaObjects providing count iteration anyway
        if varRef.showMeta == true and mt then
          vars[#vars + 1]{
            name = "<metatable>",
            value = "metatable",
            type = "metatable",
            variablesReference = variables.tableRef(mt),
          }
        end
        for i=1,#varRef.table do
          vars[#vars + 1] = variables.create(tostring(i),varRef.table[i])
        end
      else
        if mt and type(mt.__debugchildren) == "function" then
          -- don't crash a debug session for a bad user-provided formatter...
          local success,children = pcall(mt.__debugchildren,varRef.table,varRef.extra)
          if success then
            for _,var in pairs(children) do
              vars[#vars + 1] = var
            end
          else
            vars[#vars + 1] = {
              name = "<__debugchildren error>",
              value = children,
              type = "error",
              variablesReference = 0,
            }
          end
        else
          -- show metatables by default for table-like objects
          if varRef.showMeta ~= false and mt then
            vars[#vars + 1] = {
              name = "<metatable>",
              value = "metatable",
              type = "metatable",
              variablesReference = variables.tableRef(mt),
            }
          end

          local debugpairs = itermode[varRef.mode or "pairs"]
          if debugpairs then
            for k,v in debugpairs(varRef.table) do
              vars[#vars + 1] = variables.create(variables.describe(k,true),v)
            end
          else
            vars[#vars + 1] = {
              name = "<table varRef error>",
              value = "missing iterator for table varRef mode ".. varRef.mode,
              type = "error",
              variablesReference = 0,
            }
          end
        end
      end
    elseif varRef.type == "LuaObject" then
      local object = varRef.object
      if luaObjectInfo.alwaysValid[varRef.classname] or object.valid then
        if varRef.classname == "LuaItemStack" and not object.valid_for_read then
          vars[#vars + 1] = {
            name = [["valid"]],
            value = "true",
            type = "boolean",
            variablesReference = 0,
            presentationHint = { kind = "property", attributes = { "readOnly" } },
          }
          vars[#vars + 1] = {
            name = [["valid_for_read"]],
            value = "false",
            type = "boolean",
            variablesReference = 0,
            presentationHint = { kind = "property", attributes = { "readOnly" } },
          }
        else
          local keys = luaObjectInfo.expandKeys[varRef.classname]
          if not keys then print("Missing keys for class " .. varRef.classname) end
          for key,keyprops in pairs(keys) do
            if keyprops.thisAsTable then
              vars[#vars + 1] = {
                name = "[]",
                value = ("%d item%s"):format(#object, #object~=1 and "s" or ""),
                type = varRef.classname .. "[]",
                variablesReference = variables.tableRef(object, keyprops.iterMode, false),
                presentationHint = { kind = "property", attributes = { "readOnly" } },
              }
            else
              -- Not all keys are valid on all LuaObjects of a given type. Just skip the errors (or nils)
              local success,value = pcall(function() return object[key] end)
              if success and value ~= nil then
                local var = variables.create(variables.describe(key,true),value)
                if keyprops.countLine then
                  var.value = ("%d item%s"):format(#value, #value~=1 and "s" or "")
                end
                var.presentationHint = var.presentationHint or {}
                var.presentationHint.kind = "property"
                if keyprops.readOnly then
                  var.presentationHint.attributes = var.presentationHint.attributes or {}
                  var.presentationHint.attributes[#var.presentationHint.attributes + 1] = "readOnly"
                end
                vars[#vars + 1] = var
              end
            end
          end
        end
      else
        vars[#vars + 1] = {
          name = [["valid"]],
          value = "false",
          type = "boolean",
          variablesReference = 0,
          presentationHint = { kind = "property", attributes = { "readOnly" } },
        }
      end
    end
  end
  if #vars == 0 then
    vars[1] = {
      name = "<empty>",
      value = "empty",
      type = "empty",
      variablesReference = 0,
      presentationHint = { kind = "property", attributes = { "readOnly" } },
    }
  end
  print("DBGvars: " .. json.encode({variablesReference = variablesReference, vars = vars}))
end

--- DebugAdapter SetVariablesRequest
---@param variablesReference integer
---@param name string
---@param value string
---@param seq number
function __DebugAdapter.setVariable(variablesReference, name, value, seq)
  local varRef = variables.refs[variablesReference]
  if varRef then
    if varRef.type == "Locals" then
      local i = 1
      while true do
        local lname,oldvalue = debug.getlocal(varRef.frameId,i)
        if not lname then break end
        if lname:sub(1,1) == "(" then
          lname = ("%s %d)"):format(lname:sub(1,-2),i)
        end
        if lname == name then
          local goodvalue,newvalue = __DebugAdapter.evaluateInternal(varRef.frameId+1,nil,"setvar",value)
          if goodvalue then
            debug.setlocal(varRef.frameId,i,newvalue)
            print("DBGsetvar: " .. json.encode({seq = seq, body = variables.create(nil,newvalue)}))
            return
          else
            print("DBGsetvar: " .. json.encode({seq = seq, body = variables.create(nil,oldvalue)}))
            return
          end
        end
        i = i + 1
      end
      i = -1
      while true do
        local vaname,oldvalue = debug.getlocal(varRef.frameId,i)
        if not vaname then break end
        vaname = ("(*vararg %d)"):format(-i)
        if vaname == name then
          local goodvalue,newvalue = __DebugAdapter.evaluateInternal(varRef.frameId+1,nil,"setvar",value)
          if goodvalue then
            debug.setlocal(varRef.frameId,i,newvalue)
            print("DBGsetvar: " .. json.encode({seq = seq, body = variables.create(nil,newvalue)}))
            return
          else
            print("DBGsetvar: " .. json.encode({seq = seq, body = variables.create(nil,oldvalue)}))
            return
          end
        end
        i = i - 1
      end
    elseif varRef.type == "Upvalues" then
      local func = debug.getinfo(varRef.frameId,"f").func
      local i = 1
      while true do
        local upname,oldvalue = debug.getupvalue(func,i)
        if not upname then break end
        if upname == name then
          local goodvalue,newvalue = __DebugAdapter.evaluateInternal(varRef.frameId+1,nil,"setvar",value)
          if goodvalue then
            debug.setupvalue(func,i,newvalue)
            print("DBGsetvar: " .. json.encode({seq = seq, body = variables.create(nil,newvalue)}))
            return
          else
            print("DBGsetvar: " .. json.encode({seq = seq, body = variables.create(nil,oldvalue)}))
            return
          end
        end
        i = i + 1
      end
    elseif varRef.type == "Table" or varRef.type == "LuaObject" then
      -- special names "[]" and others aren't valid lua so it won't parse anyway
      local goodname,newname = __DebugAdapter.evaluateInternal(nil,nil,"setvar",name)

      local alsoLookIn = varRef.object or varRef.table
      local goodvalue,newvalue = __DebugAdapter.evaluateInternal(nil,alsoLookIn,"setvar",value)
      if goodname and goodvalue then
        -- this could fail if table has __newindex or LuaObject property is read only or wrong type, etc
        pcall(function() varRef.object[newname] = newvalue end)

        -- it could even fail silently, or coerce the value to another type,
        -- so fetch the value back instead of assuming it set...
        local _,resultvalue = pcall(function() return varRef.object[newname] end)
        print("DBGsetvar: " .. json.encode({seq = seq, body = variables.create(nil,resultvalue)}))
        return
      end
    end
  end
end

return variables