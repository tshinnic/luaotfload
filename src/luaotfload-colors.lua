if not modules then modules = { } end modules ['luaotfload-colors'] = {
    version   = "2.5",
    comment   = "companion to luaotfload-main.lua (font color)",
    author    = "Khaled Hosny, Elie Roux, Philipp Gesang",
    copyright = "Luaotfload Development Team",
    license   = "GNU GPL v2.0"
}

--[[doc--

buggy coloring with the pre_output_filter when expansion is enabled
    · tfmdata for different expansion values is split over different objects
    · in ``initializeexpansion()``, chr.expansion_factor is set, and only
      those characters that have it are affected
    · in constructors.scale: chr.expansion_factor = ve*1000 if commented out
      makes the bug vanish

explanation: http://tug.org/pipermail/luatex/2013-May/004305.html

--doc]]--

local log                   = luaotfload.log
local logreport             = log.report

local nodedirect            = node.direct
local newnode               = nodedirect.new
local insert_node_before    = nodedirect.insert_before
local insert_node_after     = nodedirect.insert_after
local todirect              = nodedirect.todirect
local tonode                = nodedirect.tonode
local setfield              = nodedirect.setfield
local getid                 = nodedirect.getid
local getfont               = nodedirect.getfont
local getlist               = nodedirect.getlist
local getsubtype            = nodedirect.getsubtype
local getnext               = nodedirect.getnext
local nodetail              = nodedirect.tail
local getattribute          = nodedirect.has_attribute
local setattribute          = nodedirect.set_attribute

local texset                = tex.set
local texget                = tex.get
local texsettoks            = tex.settoks
local texgettoks            = tex.gettoks

local stringformat          = string.format

local otffeatures           = fonts.constructors.newfeatures("otf")
local identifiers           = fonts.hashes.identifiers
local registerotffeature    = otffeatures.register

local add_color_callback --[[ this used to be a global‽ ]]

--[[doc--
This converts a single octet into a decimal with three digits of
precision. The optional second argument limits precision to a single
digit.
--doc]]--

--- string -> bool? -> string
local hex_to_dec = function (hex,one) --- one isn’t actually used anywhere ...
    if one then
        return stringformat("%.1g", tonumber(hex, 16)/255)
    else
        return stringformat("%.3g", tonumber(hex, 16)/255)
    end
end

--[[doc--
Color string validator / parser.
--doc]]--

local lpeg           = require"lpeg"
local lpegmatch      = lpeg.match
local C, Cg, Ct, P, R, S = lpeg.C, lpeg.Cg, lpeg.Ct, lpeg.P, lpeg.R, lpeg.S

local digit16        = R("09", "af", "AF")
local opaque         = S("fF") * S("fF")
local octet          = C(digit16 * digit16)

local p_rgb          = octet * octet * octet
local p_rgba         = p_rgb * (octet - opaque)
local valid_digits   = C(p_rgba + p_rgb) -- matches eight or six hex digits

local p_Crgb         = Cg(octet/hex_to_dec, "red") --- for captures
                     * Cg(octet/hex_to_dec, "green")
                     * Cg(octet/hex_to_dec, "blue")
local p_Crgba        = p_Crgb * Cg(octet/hex_to_dec, "alpha")
local extract_color  = Ct(p_Crgba + p_Crgb)

--- string -> (string | nil)
local sanitize_color_expression = function (digits)
    digits = tostring(digits)
    local sanitized = lpegmatch(valid_digits, digits)
    if not sanitized then
        logreport("both", 0, "color",
                  "%q is not a valid rgb[a] color expression",
                  digits)
        return nil
    end
    return sanitized
end

--[[doc--
``setcolor`` modifies tfmdata.properties.color in place
--doc]]--

--- fontobj -> string -> unit
---
---         (where “string” is a rgb value as three octet
---         hexadecimal, with an optional fourth transparency
---         value)
---
local setcolor = function (tfmdata, value)
    local sanitized  = sanitize_color_expression(value)
    local properties = tfmdata.properties

    if sanitized then
        properties.color = sanitized
        add_color_callback()
    end
end

registerotffeature {
    name        = "color",
    description = "color",
    initializers = {
        base = setcolor,
        node = setcolor,
    }
}


--- something is carried around in ``res``
--- for later use by color_handler() --- but what?

local res = nil

--- float -> unit
local function pageresources(alpha)
    res = res or {}
    res[alpha] = true
end

--- we store results of below color handler as tuples of
--- push/pop strings
local color_cache = { } --- (string, (string * string)) hash_t

--- string -> (string * string)
local hex_to_rgba = function (digits)
    if not digits then
        return
    end

    --- this is called like a thousand times, so some
    --- memoizing is in order.
    local cached = color_cache[digits]
    if not cached then
        local push, pop
        local rgb = lpegmatch(extract_color, digits)
        if rgb.alpha then
            pageresources(rgb.alpha)
            push = stringformat(
                        "/TransGs%g gs %s %s %s rg",
                        rgb.alpha,
                        rgb.red,
                        rgb.green,
                        rgb.blue)
            pop  = "0 g /TransGs1 gs"
        else
            push = stringformat(
                        "%s %s %s rg",
                        rgb.red,
                        rgb.green,
                        rgb.blue)
            pop  = "0 g"
        end
        color_cache[digits] = { push, pop }
        return push, pop
    end

    return cached[1], cached[2]
end

--- Luatex internal types

local nodetype          = node.id
local glyph_t           = nodetype("glyph")
local hlist_t           = nodetype("hlist")
local vlist_t           = nodetype("vlist")
local whatsit_t         = nodetype("whatsit")
local disc_t            = nodetype("disc")
local pdfliteral_t      = node.subtype("pdf_literal")
local colorstack_t      = node.subtype("pdf_colorstack")

local color_callback
local color_attr        = luatexbase.new_attribute("luaotfload_color_attribute")

-- (node * node * string * bool * (bool | nil)) -> (node * node * (string | nil))
local color_whatsit
color_whatsit = function (head, curr, color, push, tail)
    local pushdata  = hex_to_rgba(color)
    local colornode = newnode(whatsit_t, colorstack_t)
    setfield(colornode, "stack", 0)
    setfield(colornode, "command", push and 1 or 2) -- 1: push, 2: pop
    setfield(colornode, "data", push and pushdata or nil)
    if tail then
        head, curr = insert_node_after (head, curr, colornode)
    else
        head = insert_node_before(head, curr, colornode)
    end
    if not push and color:len() > 6 then
        local colornode = newnode(whatsit_t, pdfliteral_t)
        setfield(colornode, "mode", 2)
        setfield(colornode, "data", "/TransGs1 gs")
        if tail then
            head, curr = insert_node_after (head, curr, colornode)
        else
            head = insert_node_before(head, curr, colornode)
        end
    end
    color = push and color or nil
    return head, curr, color
end

-- number -> string | nil
local get_font_color = function (font_id)
    local tfmdata    = identifiers[font_id]
    local font_color = tfmdata and tfmdata.properties and tfmdata.properties.color
    return font_color
end

local cnt = 0

--[[doc--
While the second argument and second returned value are apparently
always nil when the function is called, they temporarily take string
values during the node list traversal.
--doc]]--

--- (node * (string | nil)) -> (node * (string | nil))
local node_colorize
node_colorize = function (head, current_color)
    local n = head
    while n do
        local n_id = getid(n)

        if n_id == hlist_t or n_id == vlist_t then
            cnt = cnt + 1
            local n_list = getlist(n)
            if getattribute(n_list, color_attr) then
                if current_color then
                    head, n, current_color = color_whatsit(head, n, current_color, false)
                end
            else
                n_list, current_color = node_colorize(n_list, current_color)
                if current_color and getsubtype(n) == 1 then -- created by linebreak
                    n_list, _, current_color = color_whatsit(n_list, nodetail(n_list), current_color, false, true)
                end
                setfield(n, "head", n_list)
            end
            cnt = cnt - 1

        elseif n_id == glyph_t then
            --- colorization is restricted to those fonts
            --- that received the “color” property upon
            --- loading (see ``setcolor()`` above)
            local font_color = get_font_color(getfont(n))
            if font_color ~= current_color then
                if current_color then
                    head, n, current_color = color_whatsit(head, n, current_color, false)
                end
                if font_color then
                    head, n, current_color = color_whatsit(head, n, font_color, true)
                end
            end

            if current_color and color_callback == "pre_linebreak_filter" then
                local nn = getnext(n)
                while nn and getid(nn) == glyph_t do
                    local font_color = get_font_color(getfont(nn))
                    if font_color == current_color then
                        n = nn
                    else
                        break
                    end
                    nn = getnext(nn)
                end
                if getid(nn) == disc_t then
                    head, n, current_color = color_whatsit(head, nn, current_color, false, true)
                else
                    head, n, current_color = color_whatsit(head, n, current_color, false, true)
                end
            end

        elseif n_id == whatsit_t then
            if current_color then
                head, n, current_color = color_whatsit(head, n, current_color, false)
            end

        end

        n = getnext(n)
    end

    if cnt == 0 and current_color then
        head, _, current_color = color_whatsit(head, nodetail(head), current_color, false, true)
    end

    setattribute(head, color_attr, 1)
    return head, current_color
end

--- node -> node
local color_handler = function (head)
    head = todirect(head)
    head = node_colorize(head)
    head = tonode(head)

    -- now append our page resources
    if res then
        res["1"]  = true
        local tpr = texget("pdfpageresources")
        local pgf_loaded = tpr:find("/ExtGState %d+ 0 R")
        if pgf_loaded then
            tpr = texgettoks("pgf@sys@pgf@resource@list@extgs@toks") -- see luaotfload.sty
        end

        local t   = ""
        for k in pairs(res) do
            local str = stringformat("/TransGs%s<</ca %s>>", k, k) -- don't touch stroking elements
            if not tpr:find(str) then
                t = t .. str
            end
        end
        if t ~= "" then
            if pgf_loaded then
                texsettoks("global", "pgf@sys@pgf@resource@list@extgs@toks", tpr..t)
            else
                if not tpr:find("/ExtGState<<.*>>") then
                    tpr = tpr .. "/ExtGState<<>>"
                end
                tpr = tpr:gsub("/ExtGState<<", "%1"..t)
                texset("global", "pdfpageresources", tpr)
            end
        end
        res = nil -- reset res
    end
    return head
end

local color_callback_activated = 0

--- unit -> unit
add_color_callback = function ( )
    color_callback = config.luaotfload.run.color_callback
    if not color_callback then
        color_callback = "post_linebreak_filter"
    end

    if color_callback_activated == 0 then
        luatexbase.add_to_callback(color_callback,
                                   color_handler,
                                   "luaotfload.color_handler")
        luatexbase.add_to_callback("hpack_filter",
                                   function (head, groupcode)
                                       if  groupcode == "hbox"          or
                                           groupcode == "adjusted_hbox" or
                                           groupcode == "align_set"     then
                                           head = color_handler(head)
                                       end
                                       return head
                                   end,
                                   "luaotfload.color_handler")
        color_callback_activated = 1
    end
end

-- vim:tw=71:sw=4:ts=4:expandtab

