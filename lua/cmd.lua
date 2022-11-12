local function escapeutf8 (uchar)
    local value = escapecodes[uchar]
    if value then
      return value
    end
    local a, b, c, d = strbyte (uchar, 1, 4)
    a, b, c, d = a or 0, b or 0, c or 0, d or 0
    if a <= 0x7f then
      value = a
    elseif 0xc0 <= a and a <= 0xdf and b >= 0x80 then
      value = (a - 0xc0) * 0x40 + b - 0x80
    elseif 0xe0 <= a and a <= 0xef and b >= 0x80 and c >= 0x80 then
      value = ((a - 0xe0) * 0x40 + b - 0x80) * 0x40 + c - 0x80
    elseif 0xf0 <= a and a <= 0xf7 and b >= 0x80 and c >= 0x80 and d >= 0x80 then
      value = (((a - 0xf0) * 0x40 + b - 0x80) * 0x40 + c - 0x80) * 0x40 + d - 0x80
    else
      return ""
    end
    if value <= 0xffff then
      return strformat ("\\u%.4x", value)
    elseif value <= 0x10ffff then
      -- encode as UTF-16 surrogate pair
      value = value - 0x10000
      local highsur, lowsur = 0xD800 + floor (value/0x400), 0xDC00 + (value % 0x400)
      return strformat ("\\u%.4x\\u%.4x", highsur, lowsur)
    else
      return ""
    end
  end

  local function addpair (key, value, prev, indent, level, buffer, buflen, tables, globalorder, state)
    local kt = type (key)
    if kt ~= 'string' and kt ~= 'number' then
      return nil, "type '" .. kt .. "' is not supported as a key by JSON."
    end
    if prev then
      buflen = buflen + 1
      buffer[buflen] = ","
    end
    if indent then
      buflen = addnewline2 (level, buffer, buflen)
    end
    buffer[buflen+1] = quotestring (key)
    buffer[buflen+2] = ":"
    return encode2 (value, indent, level, buffer, buflen + 2, tables, globalorder, state)
  end
  
  local function appendcustom(res, buffer, state)
    local buflen = state.bufferlen
    if type (res) == 'string' then
      buflen = buflen + 1
      buffer[buflen] = res
    end
    return buflen
  end
  
  local function exception(reason, value, state, buffer, buflen, defaultmessage)
    defaultmessage = defaultmessage or reason
    local handler = state.exception
    if not handler then
      return nil, defaultmessage
    else
      state.bufferlen = buflen
      local ret, msg = handler (reason, value, state, defaultmessage)
      if not ret then return nil, msg or defaultmessage end
      return appendcustom(ret, buffer, state)
    end
  end
  
  function json.encodeexception(reason, value, state, defaultmessage)
    return quotestring("<" .. defaultmessage .. ">")
  end
  
  encode2 = function (value, indent, level, buffer, buflen, tables, globalorder, state)
    local valtype = type (value)
    local valmeta = getmetatable (value)
    valmeta = type (valmeta) == 'table' and valmeta -- only tables
    local valtojson = valmeta and valmeta.__tojson
    if valtojson then
      if tables[value] then
        return exception('reference cycle', value, state, buffer, buflen)
      end
      tables[value] = true
      state.bufferlen = buflen
      local ret, msg = valtojson (value, state)
      if not ret then return exception('custom encoder failed', value, state, buffer, buflen, msg) end
      tables[value] = nil
      buflen = appendcustom(ret, buffer, state)
    elseif value == nil then
      buflen = buflen + 1
      buffer[buflen] = "null"
    elseif valtype == 'number' then
      local s
      if value ~= value or value >= huge or -value >= huge then
        -- This is the behaviour of the original JSON implementation.
        s = "null"
      else
        s = num2str (value)
      end
      buflen = buflen + 1
      buffer[buflen] = s
    elseif valtype == 'boolean' then
      buflen = buflen + 1
      buffer[buflen] = value and "true" or "false"
    elseif valtype == 'string' then
      buflen = buflen + 1
      buffer[buflen] = quotestring (value)
    elseif valtype == 'table' then
      if tables[value] then
        return exception('reference cycle', value, state, buffer, buflen)
      end
      tables[value] = true
      level = level + 1
      local isa, n = isarray (value)
      if n == 0 and valmeta and valmeta.__jsontype == 'object' then
        isa = false
      end
      local msg
      if isa then -- JSON array
        buflen = buflen + 1
        buffer[buflen] = "["
        for i = 1, n do
          buflen, msg = encode2 (value[i], indent, level, buffer, buflen, tables, globalorder, state)
          if not buflen then return nil, msg end
          if i < n then
            buflen = buflen + 1
            buffer[buflen] = ","
          end
        end
        buflen = buflen + 1
        buffer[buflen] = "]"
      else -- JSON object
        local prev = false
        buflen = buflen + 1
        buffer[buflen] = "{"
        local order = valmeta and valmeta.__jsonorder or globalorder
        if order then
          local used = {}
          n = #order
          for i = 1, n do
            local k = order[i]
            local v = value[k]
            if v then
              used[k] = true
              buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
              prev = true -- add a seperator before the next element
            end
          end
          for k,v in pairs (value) do
            if not used[k] then
              buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
              if not buflen then return nil, msg end
              prev = true -- add a seperator before the next element
            end
          end
        else -- unordered
          for k,v in pairs (value) do
            buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
            if not buflen then return nil, msg end
            prev = true -- add a seperator before the next element
          end
        end
        if indent then
          buflen = addnewline2 (level - 1, buffer, buflen)
        end
        buflen = buflen + 1
        buffer[buflen] = "}"
      end
      tables[value] = nil
    else
      return exception ('unsupported type', value, state, buffer, buflen,
        "type '" .. valtype .. "' is not supported by JSON.")
    end
    return buflen
  end