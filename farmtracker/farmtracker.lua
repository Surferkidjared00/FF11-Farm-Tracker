addon.name      = 'FarmTracker'
addon.author    = 'mobpsycho'
addon.version   = '1.1.0'
addon.desc      = 'Tracks farming sessions with drop rates'
addon.link      = ''

require('common')
local imgui = require('imgui')
local json = require('json')

-- Bitreader for packet parsing (from Ashita examples)
local bitreader = T{
    data = nil,
    bit = 0,
    pos = 0,
}

function bitreader:new(o)
    o = o or T{}
    setmetatable(o, self)
    self.__index = self
    return o
end

function bitreader:set_data(data)
    self.bit = 0
    self.data = T{}
    self.pos = 0
    
    if type(data) == 'string' then
        data:hex():gsub('(%x%x)', function(x)
            table.insert(self.data, tonumber(x, 16))
        end)
    else
        self.data = data
    end
end

function bitreader:read(bits)
    local ret = 0
    if self.data == nil then return ret end
    
    for x = 0, bits - 1 do
        local val = bit.lshift(bit.band(self.data[self.pos + 1], 1), x)
        self.data[self.pos + 1] = bit.rshift(self.data[self.pos + 1], 1)
        ret = bit.bor(ret, val)
        
        self.bit = self.bit + 1
        if self.bit == 8 then
            self.bit = 0
            self.pos = self.pos + 1
        end
    end
    
    return ret
end

-- Main addon state
local farmtracker = {
    session = {
        active = false,
        started = false,
        start_time = 0,
        name = "",
        zone = "",
        
        -- Tracking data
        mobs_killed = {},      -- [mob_name] = count
        items_dropped = {},    -- [item_name] = {total = n, by_mob = {[mob_name] = count}}
        items_obtained = {},   -- [item_name] = count
        gil_obtained = 0,
        
        -- Temporary tracking
        last_mob = "",
        treasure_pool = {},    -- [index] = {item_name, mob_name}
    },
    
    -- Settings
    settings = {
        track_all_drops = true,
        show_window = true,
        mini_mode = false,
        active_tab = 1,
        
        -- Item prices
        prices = {},
    },
    
    -- UI state
    ui = {
        main_window = {true},
    },
    
    -- Debug
    debug = false,
}

-- File paths
local addon_path = string.format('%sconfig/addons/%s/', AshitaCore:GetInstallPath(), addon.name)
local settings_file = addon_path .. 'settings.json'
local sessions_file = addon_path .. 'sessions.json'

-- Create directory if it doesn't exist
ashita.fs.create_directory(addon_path)

-- Save settings
local function save_settings()
    local f = io.open(settings_file, 'w')
    if f then
        f:write(json.encode(farmtracker.settings))
        f:close()
    end
end

-- Load settings
local function load_settings()
    local f = io.open(settings_file, 'r')
    if f then
        local content = f:read('*all')
        f:close()
        
        local ok, data = pcall(json.decode, content)
        if ok and data then
            farmtracker.settings = data
            farmtracker.ui.main_window[1] = farmtracker.settings.show_window
        end
    end
end

-- Format number with commas
local function format_number(n)
    if not n then return "0" end
    local formatted = tostring(math.floor(n))
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

-- Format duration
local function format_duration(seconds)
    if not seconds or seconds <= 0 then return "00:00:00" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

-- Get current zone name
local function get_zone_name()
    local zone_id = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
    local zone_name = AshitaCore:GetResourceManager():GetString("zones.names", zone_id)
    return zone_name or "Unknown"
end

-- Check if someone is in party/alliance
local function is_party_member(name)
    if not name then return false end
    local party = AshitaCore:GetMemoryManager():GetParty()
    
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 then
            if party:GetMemberName(i) == name then
                return true
            end
        end
    end
    
    return false
end

-- Start a new session
local function start_session()
    farmtracker.session = {
        active = true,
        started = false,
        start_time = 0,
        name = "",
        zone = get_zone_name(),
        
        mobs_killed = {},
        items_dropped = {},
        items_obtained = {},
        gil_obtained = 0,
        
        last_mob = "",
        treasure_pool = {},
    }
    
    print('[FarmTracker] Session started! Timer begins after first kill.')
end

-- Stop session
local function stop_session()
    if farmtracker.session.started then
        farmtracker.session.active = false
        -- TODO: Save session to history
        print('[FarmTracker] Session stopped!')
    end
end

-- Track mob kill
local function add_mob_kill(mob_name)
    if not farmtracker.session.active or not mob_name or mob_name == "" then
        return
    end
    
    -- Start timer on first kill
    if not farmtracker.session.started then
        farmtracker.session.started = true
        farmtracker.session.start_time = os.time()
        print('[FarmTracker] Timer started!')
    end
    
    -- Clean mob name
    mob_name = mob_name:gsub("^[Tt]he%s+", "")
    
    -- Track kill
    if not farmtracker.session.mobs_killed[mob_name] then
        farmtracker.session.mobs_killed[mob_name] = 0
    end
    farmtracker.session.mobs_killed[mob_name] = farmtracker.session.mobs_killed[mob_name] + 1
    farmtracker.session.last_mob = mob_name
    
    print(string.format('[FarmTracker] Killed: %s (Total: %d)', 
        mob_name, farmtracker.session.mobs_killed[mob_name]))
end

-- Track item drop
local function add_item_drop(item_name, mob_name)
    if not farmtracker.session.active or not item_name then
        return
    end
    
    -- Initialize item entry
    if not farmtracker.session.items_dropped[item_name] then
        farmtracker.session.items_dropped[item_name] = {
            total = 0,
            by_mob = {}
        }
    end
    
    -- Increment total
    farmtracker.session.items_dropped[item_name].total = 
        farmtracker.session.items_dropped[item_name].total + 1
    
    -- Track by mob if known
    if mob_name and mob_name ~= "" then
        mob_name = mob_name:gsub("^[Tt]he%s+", "")
        
        if not farmtracker.session.items_dropped[item_name].by_mob[mob_name] then
            farmtracker.session.items_dropped[item_name].by_mob[mob_name] = 0
        end
        
        farmtracker.session.items_dropped[item_name].by_mob[mob_name] = 
            farmtracker.session.items_dropped[item_name].by_mob[mob_name] + 1
    end
    
    if farmtracker.debug then
        print(string.format('[FarmTracker] Drop: %s from %s', item_name, mob_name or "Unknown"))
    end
end

-- Track item obtained
local function add_item_obtained(item_name, count)
    if not farmtracker.session.active or not item_name then
        return
    end
    
    count = count or 1
    
    if not farmtracker.session.items_obtained[item_name] then
        farmtracker.session.items_obtained[item_name] = 0
    end
    
    farmtracker.session.items_obtained[item_name] = 
        farmtracker.session.items_obtained[item_name] + count
    
    -- Add value if price is set
    local price = farmtracker.settings.prices[item_name] or 0
    if price > 0 then
        farmtracker.session.gil_obtained = farmtracker.session.gil_obtained + (price * count)
    end
    
    print(string.format('[FarmTracker] Obtained: %dx %s', count, item_name))
end

-- Calculate drop rate
local function calc_drop_rate(item_name, mob_name)
    local drops = farmtracker.session.items_dropped[item_name]
    if not drops then return 0 end
    
    local drop_count = 0
    local kill_count = 0
    
    if mob_name then
        drop_count = drops.by_mob[mob_name] or 0
        kill_count = farmtracker.session.mobs_killed[mob_name] or 0
    else
        drop_count = drops.total
        for _, count in pairs(farmtracker.session.mobs_killed) do
            kill_count = kill_count + count
        end
    end
    
    if kill_count == 0 then return 0 end
    return (drop_count / kill_count) * 100
end

-- Handle incoming packets
ashita.events.register('packet_in', 'farmtracker_packets', function(e)
    -- Message packet (mob defeats, gil)
    if e.id == 0x0029 then
        local reader = bitreader:new()
        reader:set_data(e.data)
        reader:read(32) -- skip first 4 bytes
        
        local actor_id = reader:read(32)
        local target_id = reader:read(32)
        local param1 = reader:read(32)
        local param2 = reader:read(32)
        local actor_index = reader:read(16)
        local target_index = reader:read(16)
        local message_id = reader:read(16)
        
        local entity = AshitaCore:GetMemoryManager():GetEntity()
        
        -- Mob defeated (message 6)
        if message_id == 6 then
            local actor_name = entity:GetName(actor_index)
            if actor_name and is_party_member(actor_name) then
                local target_name = entity:GetName(target_index)
                if target_name and target_name ~= "" then
                    add_mob_kill(target_name)
                end
            end
        
        -- Gil messages
        elseif message_id == 565 or message_id == 566 or message_id == 810 then
            if farmtracker.session.active and param1 > 0 then
                farmtracker.session.gil_obtained = farmtracker.session.gil_obtained + param1
                add_item_obtained("Gil", param1)
            end
        end
    
    -- Item drop packet
    elseif e.id == 0x00D2 then
        local reader = bitreader:new()
        reader:set_data(e.data)
        reader:read(32) -- skip header
        
        local index = reader:read(32)
        reader:read(32) -- unknown
        reader:read(32) -- count
        local item_id = reader:read(16)
        local dropper_index = reader:read(16)
        
        if item_id > 0 then
            local entity = AshitaCore:GetMemoryManager():GetEntity()
            local mob_name = entity:GetName(dropper_index)
            
            local item = AshitaCore:GetResourceManager():GetItemById(item_id)
            if item then
                local item_name = item.Name[1]
                
                -- Store in pool
                farmtracker.session.treasure_pool[index] = {
                    item = item_name,
                    mob = mob_name
                }
                
                -- Track drop
                add_item_drop(item_name, mob_name)
                
                -- Auto-track if enabled
                if farmtracker.settings.track_all_drops then
                    add_item_obtained(item_name, 1)
                end
            end
        end
    
    -- Item obtained packet
    elseif e.id == 0x00D3 then
        local reader = bitreader:new()
        reader:set_data(e.data)
        reader:read(32) -- skip header
        
        local index = reader:read(32)
        reader:read(32) -- unknown
        local player_index = reader:read(16)
        reader:read(16) -- unknown
        local drop_type = reader:read(8)
        
        -- drop_type: 1 = drop to floor, 5 = obtained
        if drop_type == 5 then
            local party = AshitaCore:GetMemoryManager():GetParty()
            local my_index = party:GetMemberTargetIndex(0)
            
            if player_index == my_index then
                local pool_item = farmtracker.session.treasure_pool[index]
                if pool_item and not farmtracker.settings.track_all_drops then
                    add_item_obtained(pool_item.item, 1)
                end
            end
        end
        
        -- Clear from pool
        farmtracker.session.treasure_pool[index] = nil
    end
end)

-- Render UI
local function render_ui()
    -- Mini mode
    if farmtracker.settings.mini_mode then
        imgui.SetNextWindowSize({350, 300}, ImGuiCond_FirstUseEver)
        if imgui.Begin('FarmTracker Mini', farmtracker.ui.main_window, ImGuiWindowFlags_NoTitleBar) then
            if farmtracker.session.active and farmtracker.session.started then
                local elapsed = os.time() - farmtracker.session.start_time
                local total_kills = 0
                for _, count in pairs(farmtracker.session.mobs_killed) do
                    total_kills = total_kills + count
                end
                
                -- Header stats
                imgui.TextColored({0.7, 0.7, 0.7, 1.0}, 'Time: ')
                imgui.SameLine()
                imgui.Text(format_duration(elapsed))
                imgui.SameLine()
                imgui.TextColored({0.7, 0.7, 0.7, 1.0}, ' Kills: ')
                imgui.SameLine()
                imgui.Text(tostring(total_kills))
                imgui.SameLine()
                imgui.TextColored({0.7, 0.7, 0.7, 1.0}, ' Gil: ')
                imgui.SameLine()
                imgui.TextColored({1.0, 0.8, 0.3, 1.0}, format_number(farmtracker.session.gil_obtained))
                
                imgui.Separator()
                
                -- Mobs section
                imgui.TextColored({0.8, 0.8, 0.8, 1.0}, 'Monsters:')
                for mob, count in pairs(farmtracker.session.mobs_killed) do
                    imgui.Text(string.format('  %s: %d', mob, count))
                end
                
                imgui.Separator()
                
                -- Items section
                imgui.TextColored({0.8, 0.8, 0.8, 1.0}, 'Items:')
                
                -- Collect all items
                local all_items = {}
                for item in pairs(farmtracker.session.items_obtained) do
                    all_items[item] = true
                end
                for item in pairs(farmtracker.session.items_dropped) do
                    all_items[item] = true
                end
                
                -- Display items with drop rates
                for item in pairs(all_items) do
                    if item ~= "Gil" then
                        local obtained = farmtracker.session.items_obtained[item] or 0
                        local drop_data = farmtracker.session.items_dropped[item]
                        local dropped = drop_data and drop_data.total or 0
                        local rate = calc_drop_rate(item)
                        
                        imgui.Text(string.format('  %s: %d', item, obtained))
                        if rate > 0 then
                            imgui.SameLine()
                            imgui.TextColored({0.5, 0.5, 1.0, 1.0}, string.format(' (%.1f%%)', rate))
                        end
                    end
                end
            else
                imgui.TextColored({0.5, 0.5, 0.5, 1.0}, 'Session inactive')
            end
            
            if imgui.IsMouseDoubleClicked(0) and imgui.IsWindowHovered() then
                farmtracker.settings.mini_mode = false
                save_settings()
            end
        end
        imgui.End()
        return
    end
    
    -- Main window
    imgui.SetNextWindowSize({600, 500}, ImGuiCond_FirstUseEver)
    if imgui.Begin('FarmTracker', farmtracker.ui.main_window) then
        -- Controls
        if farmtracker.session.active then
            if imgui.Button('Stop Session') then
                stop_session()
            end
            imgui.SameLine()
            if imgui.Button('Reset') then
                start_session()
            end
        else
            if imgui.Button('Start Session') then
                start_session()
            end
        end
        
        imgui.SameLine()
        if imgui.Button(farmtracker.settings.mini_mode and 'Normal' or 'Mini') then
            farmtracker.settings.mini_mode = not farmtracker.settings.mini_mode
            save_settings()
        end
        
        imgui.SameLine()
        local track_all = {farmtracker.settings.track_all_drops}
        if imgui.Checkbox('Track All Drops', track_all) then
            farmtracker.settings.track_all_drops = track_all[1]
            save_settings()
        end
        
        if imgui.IsItemHovered() then
            imgui.SetTooltip('ON: Track all dropped items\nOFF: Track only obtained items')
        end
        
        -- Debug toggle
        imgui.SameLine()
        if imgui.Button('Debug') then
            farmtracker.debug = not farmtracker.debug
            print('[FarmTracker] Debug: ' .. (farmtracker.debug and 'ON' or 'OFF'))
        end
        
        -- Session info
        if farmtracker.session.active then
            imgui.Separator()
            
            -- Stats
            local elapsed = 0
            if farmtracker.session.started then
                elapsed = os.time() - farmtracker.session.start_time
            end
            
            local total_kills = 0
            for _, count in pairs(farmtracker.session.mobs_killed) do
                total_kills = total_kills + count
            end
            
            local total_items = 0
            for _, count in pairs(farmtracker.session.items_obtained) do
                total_items = total_items + count
            end
            
            -- Display stats in columns
            if imgui.BeginTable('Stats', 4, ImGuiTableFlags_SizingStretchSame) then
                imgui.TableNextColumn()
                imgui.Text('Time:')
                imgui.Text(format_duration(elapsed))
                
                imgui.TableNextColumn()
                imgui.Text('Kills:')
                imgui.Text(tostring(total_kills))
                
                imgui.TableNextColumn()
                imgui.Text('Items:')
                imgui.Text(tostring(total_items))
                
                imgui.TableNextColumn()
                imgui.Text('Gil:')
                imgui.TextColored({1.0, 0.8, 0.3, 1.0}, format_number(farmtracker.session.gil_obtained))
                
                imgui.EndTable()
            end
            
            imgui.Separator()
            
            -- Tabs
            if imgui.BeginTabBar('FarmTabs') then
                -- Mobs tab
                if imgui.BeginTabItem('Mobs') then
                    if imgui.BeginTable('Mobs', 2, ImGuiTableFlags_Borders + ImGuiTableFlags_RowBg) then
                        imgui.TableSetupColumn('Monster', ImGuiTableColumnFlags_WidthStretch)
                        imgui.TableSetupColumn('Kills', ImGuiTableColumnFlags_WidthFixed, 60)
                        imgui.TableHeadersRow()
                        
                        for mob, count in pairs(farmtracker.session.mobs_killed) do
                            imgui.TableNextRow()
                            imgui.TableNextColumn()
                            imgui.Text(mob)
                            imgui.TableNextColumn()
                            imgui.Text(tostring(count))
                        end
                        
                        imgui.EndTable()
                    end
                    imgui.EndTabItem()
                end
                
                -- Items tab
                if imgui.BeginTabItem('Items') then
                    if imgui.BeginTable('Items', 5, ImGuiTableFlags_Borders + ImGuiTableFlags_RowBg) then
                        imgui.TableSetupColumn('Item', ImGuiTableColumnFlags_WidthStretch)
                        imgui.TableSetupColumn('Obtained', ImGuiTableColumnFlags_WidthFixed, 60)
                        imgui.TableSetupColumn('Dropped', ImGuiTableColumnFlags_WidthFixed, 60)
                        imgui.TableSetupColumn('Rate %', ImGuiTableColumnFlags_WidthFixed, 60)
                        imgui.TableSetupColumn('From', ImGuiTableColumnFlags_WidthFixed, 120)
                        imgui.TableHeadersRow()
                        
                        -- Collect all items
                        local all_items = {}
                        for item in pairs(farmtracker.session.items_obtained) do
                            all_items[item] = true
                        end
                        for item in pairs(farmtracker.session.items_dropped) do
                            all_items[item] = true
                        end
                        
                        -- Display items
                        for item in pairs(all_items) do
                            imgui.TableNextRow()
                            imgui.TableNextColumn()
                            imgui.Text(item)
                            
                            imgui.TableNextColumn()
                            local obtained = farmtracker.session.items_obtained[item] or 0
                            imgui.Text(tostring(obtained))
                            
                            imgui.TableNextColumn()
                            local drop_data = farmtracker.session.items_dropped[item]
                            local dropped = drop_data and drop_data.total or 0
                            imgui.Text(tostring(dropped))
                            
                            imgui.TableNextColumn()
                            local rate = calc_drop_rate(item)
                            if rate > 0 then
                                imgui.TextColored({0.5, 0.5, 1.0, 1.0}, string.format("%.1f", rate))
                            else
                                imgui.TextColored({0.5, 0.5, 0.5, 1.0}, "---")
                            end
                            
                            imgui.TableNextColumn()
                            if drop_data and drop_data.by_mob then
                                local mob_list = ""
                                for mob, _ in pairs(drop_data.by_mob) do
                                    if mob_list ~= "" then mob_list = mob_list .. ", " end
                                    mob_list = mob_list .. mob
                                end
                                imgui.Text(mob_list)
                            else
                                imgui.TextColored({0.5, 0.5, 0.5, 1.0}, "---")
                            end
                        end
                        
                        imgui.EndTable()
                    end
                    imgui.EndTabItem()
                end
                
                -- Prices tab
                if imgui.BeginTabItem('Prices') then
                    if imgui.BeginTable('Prices', 3, ImGuiTableFlags_Borders + ImGuiTableFlags_RowBg) then
                        imgui.TableSetupColumn('Item', ImGuiTableColumnFlags_WidthStretch)
                        imgui.TableSetupColumn('Price', ImGuiTableColumnFlags_WidthFixed, 100)
                        imgui.TableSetupColumn('Total', ImGuiTableColumnFlags_WidthFixed, 100)
                        imgui.TableHeadersRow()
                        
                        local grand_total = 0
                        
                        for item, count in pairs(farmtracker.session.items_obtained) do
                            if item ~= "Gil" then
                                imgui.TableNextRow()
                                imgui.TableNextColumn()
                                imgui.Text(item)
                                
                                imgui.TableNextColumn()
                                local price = farmtracker.settings.prices[item] or 0
                                local price_input = {price}
                                imgui.PushItemWidth(-1)
                                if imgui.InputInt('##price_' .. item, price_input) then
                                    if price_input[1] >= 0 then
                                        farmtracker.settings.prices[item] = price_input[1]
                                        save_settings()
                                    end
                                end
                                imgui.PopItemWidth()
                                
                                imgui.TableNextColumn()
                                local total = price * count
                                grand_total = grand_total + total
                                if total > 0 then
                                    imgui.TextColored({0.5, 1.0, 0.5, 1.0}, format_number(total))
                                else
                                    imgui.TextColored({0.5, 0.5, 0.5, 1.0}, "---")
                                end
                            end
                        end
                        
                        -- Total row
                        imgui.TableNextRow()
                        imgui.TableNextColumn()
                        imgui.Text('Total Value:')
                        imgui.TableNextColumn()
                        imgui.TableNextColumn()
                        imgui.TextColored({1.0, 0.8, 0.3, 1.0}, format_number(grand_total))
                        
                        imgui.EndTable()
                    end
                    imgui.EndTabItem()
                end
                
                imgui.EndTabBar()
            end
        else
            imgui.TextColored({0.5, 0.5, 0.5, 1.0}, 'No active session. Click "Start Session" to begin.')
        end
    end
    imgui.End()
end

-- Commands
ashita.events.register('command', 'farmtracker_cmd', function(e)
    local args = e.command:args()
    if #args == 0 or args[1] ~= '/farm' then return end
    
    e.blocked = true
    
    if #args == 1 then
        farmtracker.ui.main_window[1] = not farmtracker.ui.main_window[1]
        farmtracker.settings.show_window = farmtracker.ui.main_window[1]
        save_settings()
        return
    end
    
    local cmd = args[2]:lower()
    
    if cmd == 'help' then
        print('[FarmTracker] Commands:')
        print('  /farm - Toggle window')
        print('  /farm start - Start session')
        print('  /farm stop - Stop session')
        print('  /farm mini - Toggle mini mode')
        print('  /farm debug - Toggle debug mode')
        print('  /farm test - Add test data')
    elseif cmd == 'start' then
        start_session()
    elseif cmd == 'stop' then
        stop_session()
    elseif cmd == 'mini' then
        farmtracker.settings.mini_mode = not farmtracker.settings.mini_mode
        save_settings()
    elseif cmd == 'debug' then
        farmtracker.debug = not farmtracker.debug
        print('[FarmTracker] Debug: ' .. (farmtracker.debug and 'ON' or 'OFF'))
    elseif cmd == 'test' then
        if not farmtracker.session.active then
            start_session()
        end
        add_mob_kill("Test Mandragora")
        add_item_drop("Test Item", "Test Mandragora")
        add_item_obtained("Test Item", 1)
        print('[FarmTracker] Test data added')
    end
end)

-- Render event
ashita.events.register('d3d_present', 'farmtracker_render', function()
    if farmtracker.ui.main_window[1] then
        render_ui()
    end
end)

-- Load event
ashita.events.register('load', 'farmtracker_load', function()
    load_settings()
    print('[FarmTracker] v1.1.0 loaded! Type /farm help for commands.')
end)

-- Unload event
ashita.events.register('unload', 'farmtracker_unload', function()
    save_settings()
end)