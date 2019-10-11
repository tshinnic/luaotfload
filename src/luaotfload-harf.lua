local harf = luaharfbuzz or require'luaharfbuzz'

local GSUBtag = harf.Tag.new("GSUB")
local GPOStag = harf.Tag.new("GPOS")
local dflttag = harf.Tag.new("dflt")

local aux = luaotfload.aux

local aux_provides_script = aux.provides_script
aux.provides_script = function(fontid, script)
  local fontdata = font.getfont(fontid)
  local hbdata = fontdata and fontdata.hb
  if hbdata then
    local hbshared = hbdata.shared
    local hbface = hbshared.face

    local script = harf.Tag.new(script)
    for _, tag in next, { GSUBtag, GPOStag } do
      local scripts = hbface:ot_layout_get_script_tags(tag) or {}
      for i = 1, #scripts do
        if script == scripts[i] then return true end
      end
    end
    return false
  end
  return aux_provides_script(fontid, script)
end

local aux_provides_language = aux.provides_language
aux.provides_language = function(fontid, script, language)
  local fontdata = font.getfont(fontid)
  local hbdata = fontdata and fontdata.hb
  if hbdata then
    local hbshared = hbdata.shared
    local hbface = hbshared.face

    local script = harf.Tag.new(script)
    -- fontspec seems to incorrectly use “DFLT” for language instead of “dflt”.
    local language = harf.Tag.new(language == "DFLT" and "dflt" or language)

    for _, tag in next, { GSUBtag, GPOStag } do
      local scripts = hbface:ot_layout_get_script_tags(tag) or {}
      for i = 1, #scripts do
        if script == scripts[i] then
          if language == dflttag then
            -- By definition “dflt” language is always present.
            return true
          else
            local languages = hbface:ot_layout_get_language_tags(tag, i - 1) or {}
            for j = 1, #languages do
              if language == languages[j] then return true end
            end
          end
        end
      end
    end
    return false
  end
  return aux_provides_language(fontid, script, language)
end

local aux_provides_feature = aux.provides_feature
aux.provides_feature = function(fontid, script, language, feature)
  local fontdata = font.getfont(fontid)
  local hbdata = fontdata and fontdata.hb
  if hbdata then
    local hbshared = hbdata.shared
    local hbface = hbshared.face

    local script = harf.Tag.new(script)
    -- fontspec seems to incorrectly use “DFLT” for language instead of “dflt”.
    local language = harf.Tag.new(language == "DFLT" and "dflt" or language)
    local feature = harf.Tag.new(feature)

    for _, tag in next, { GSUBtag, GPOStag } do
      local _, script_idx = hbface:ot_layout_find_script(tag, script)
      local _, language_idx = hbface:ot_layout_find_language(tag, script_idx, language)
      if hbface:ot_layout_find_feature(tag, script_idx, language_idx, feature) then
        return true
      end
    end
    return false
  end
  return aux_provides_feature(fontid, script, language, feature)
end

local aux_font_has_glyph = aux.font_has_glyph
aux.font_has_glyph = function(fontid, codepoint)
  local fontdata = font.getfont(fontid)
  local hbdata = fontdata and fontdata.hb
  if hbdata then
    local hbshared = hbdata.shared
    local unicodes = hbshared.unicodes
    return unicodes[codepoint] ~= nil
  end
  return aux_font_has_glyph(fontid, codepoint)
end

local aux_slot_of_name = aux.slot_of_name
aux.slot_of_name = function(fontid, glyphname, unsafe)
  local fontdata = font.getfont(fontid)
  local hbdata = fontdata and fontdata.hb
  if hbdata then
    local hbshared = hbdata.shared
    local nominals = hbshared.nominals
    local hbfont = hbshared.font

    local gid = hbfont:get_glyph_from_name(glyphname)
    if gid ~= nil then
      return nominals[gid] or gid + hbshared.gid_offset
    end
    return nil
  end
  return aux_slot_of_name(fontid, glyphname, unsafe)
end

local aux_name_of_slot = aux.name_of_slot
aux.name_of_slot = function(fontid, codepoint)
  local fontdata = font.getfont(fontid)
  local hbdata = fontdata and fontdata.hb
  if hbdata then
    local hbshared = hbdata.shared
    local hbfont = hbshared.font
    local characters = fontdata.characters
    local character = characters[codepoint]

    if character then
      local gid = characters[codepoint].index
      return hbfont:get_glyph_name(gid)
    end
    return nil
  end
  return aux_name_of_slot(fontid, codepoint)
end