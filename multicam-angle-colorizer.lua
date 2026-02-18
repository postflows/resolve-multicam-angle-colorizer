-- ================================================
-- Multicam Angle Colorizer
-- Part of PostFlows toolkit for DaVinci Resolve
-- https://github.com/postflows
-- ================================================

--[[
    Multicam Angle Colorizer

    Purpose:
    Colorize multicam timeline clips based on detected camera/angle index from clip names.
    Supports both video and audio tracks from multicam sources.

    Modes:
    - Automatic: Automatically assigns colors to first 10 angles using default color palette.
    - Manual: Shows list of found angles (up to 10 visible) with ComboBoxes for selecting colors.
      If more than 10 angles found, shows 10 rows and user can select any angle from dropdown.
      Supports "Bypass" option to skip coloring specific angles.
    - Individual: Quick mode for coloring a single angle. One ComboBox for angle selection,
      one for color. Useful when you need to color just one specific angle.

    Features:
    - Automatically detects angles from clip names:
      * Standard patterns: "Angle 1", "Cam2", "A3", etc.
      * Compound-based multicam: "Multicam - Video 1", "MULTICAM - Video 2", etc.
      * Simple video tracks: "Video 1", "Video 2", etc.
    - Works with both video and audio tracks
    - Dynamic UI that adapts to number of found angles
    - Supports up to 16 Resolve clip colors

    Author: Sergey Knyazkov (sergey.kniazkov@gmail.com)
    Version: 1.0

    Notes:
    - This script runs inside DaVinci Resolve (Lua).
    - Clip names should contain angle hints like "Angle 1", "Cam2", "A3", etc.
]]


local resolve = Resolve()
local projectManager = resolve and resolve:GetProjectManager() or nil
local project = projectManager and projectManager:GetCurrentProject() or nil
local timeline = project and project:GetCurrentTimeline() or nil

if not resolve then
    print("[Error] Resolve() object is not available")
    return
end

if not project then
    print("[Error] No project open")
    return
end

if not timeline then
    print("[Error] No active timeline")
    return
end

-- Debug mode
local DEBUG_MODE = false
local function debugPrint(...)
    if DEBUG_MODE then
        print("[Debug]", ...)
    end
end

-- Color list (Resolve clip color names - from DaVinci Resolve palette)
local ALL_COLORS = {
    "Orange", "Apricot", "Yellow", "Lime", "Olive", "Green",
    "Teal", "Navy", "Blue", "Purple", "Violet", "Pink",
    "Tan", "Beige", "Brown", "Chocolate"
}

-- Maximum number of angles to display at once
local MAX_DISPLAYED_ANGLES = 10

-- Default colors per angle index (1-based)
local DEFAULT_ANGLE_COLORS = {
    [1] = "Orange",
    [2] = "Green",
    [3] = "Yellow",
    [4] = "Blue",
    [5] = "Purple",
    [6] = "Teal",
    [7] = "Pink",
    [8] = "Brown"
}

----------------------------------------------------------------------
-- Angle detection based on clip name
----------------------------------------------------------------------

local function detectAngleFromName(name)
    if not name or name == "" then
        return nil
    end

    local lower = string.lower(name)

    -- Common patterns:
    -- "Angle 1", "Angle_2", "Angle-3"
    local n = lower:match("angle[%s%-%_]*(%d+)")
    if not n then
        -- "Cam 1", "Camera2", "Cam-3"
        n = lower:match("cam[%s%-%_]*(%d+)")
    end
    if not n then
        -- "Multicam - Video 1", "MULTICAM - Video 2", "Multicam...Video 3"
        -- This pattern appears when multicam is created from compound clips
        n = lower:match("multicam[%s%-%_%.]-%s*video[%s%-%_]*(%d+)")
    end
    if not n then
        -- "Video 1", "Video 2", "Video_3", "Video-4"
        -- Simple video track naming
        n = lower:match("video[%s%-%_]*(%d+)")
    end
    if not n then
        -- "Multicam File Name - Audio 1", "Multicam File Name - Audio 2", "Audio_3", "Audio-4"
        -- Audio track naming (multicam clip or standalone)
        n = lower:match("audio[%s%-%_]*(%d+)")
    end
    if not n then
        -- "A1", "_A2", "-A3" (avoid catching part of a longer word)
        n = lower:match("[_%-%s]a(%d+)")
        if not n then
            -- At start of name: "A1 Some text"
            n = lower:match("^a(%d+)")
        end
    end

    local idx = tonumber(n)
    if idx and idx >= 1 then
        return idx
    end
    return nil
end

----------------------------------------------------------------------
-- Core coloring logic
----------------------------------------------------------------------

local function collectAnglesOnTimeline()
    local anglesFound = {}
    
    -- Scan both video and audio tracks
    for _, trackType in ipairs({"video", "audio"}) do
        local trackCount = timeline:GetTrackCount(trackType)

        for trackIndex = 1, trackCount do
            local clips = timeline:GetItemListInTrack(trackType, trackIndex)
            if clips then
                for _, clip in ipairs(clips) do
                    local name = clip:GetName()
                    local angle = detectAngleFromName(name)
                    if angle then
                        anglesFound[angle] = true
                    end
                end
            end
        end
    end

    return anglesFound
end

-- Get sorted list of found angles
local function getFoundAnglesList()
    local anglesFound = collectAnglesOnTimeline()
    local anglesList = {}
    for angle, _ in pairs(anglesFound) do
        table.insert(anglesList, angle)
    end
    table.sort(anglesList)
    return anglesList
end

-- Build automatic color map for found angles without repeats (until ALL_COLORS is exhausted)
local function buildAutomaticAngleColorMap()
    local foundAngles = getFoundAnglesList()
    debugPrint("buildAutomaticAngleColorMap: foundAngles count =", #foundAngles)
    if #foundAngles == 0 then
        for i = 1, MAX_DISPLAYED_ANGLES do
            table.insert(foundAngles, i)
        end
    end

    local map = {}
    local used = {} -- colorName -> true
    local paletteIndex = 1

    local function nextUnusedColor()
        -- First try to find an unused color in ALL_COLORS
        for _ = 1, #ALL_COLORS do
            local c = ALL_COLORS[paletteIndex]
            paletteIndex = (paletteIndex % #ALL_COLORS) + 1
            if not used[c] then
                return c
            end
        end
        -- If we have more angles than colors, allow repeats (stable cycling)
        local c = ALL_COLORS[paletteIndex]
        paletteIndex = (paletteIndex % #ALL_COLORS) + 1
        return c
    end

    for _, angle in ipairs(foundAngles) do
        local preferred = DEFAULT_ANGLE_COLORS[angle]
        local chosen = nil

        if preferred and not used[preferred] then
            chosen = preferred
        else
            chosen = nextUnusedColor()
        end

        map[angle] = chosen
        used[chosen] = true
    end

    debugPrint("buildAutomaticAngleColorMap: returning map with", #foundAngles, "angles")
    return map
end

local function buildAngleColorMapFromUI(itm)
    local map = {}
    local mode = itm.ModeCombo.CurrentText
    debugPrint("buildAngleColorMapFromUI: mode =", mode)
    
    if mode == "Individual" then
        -- Individual mode: single angle selection
        local angleCombo = itm.IndividualAngleCombo
        local colorCombo = itm.IndividualColorCombo
        
        if angleCombo and colorCombo then
            local selectedAngle = angleCombo.CurrentText
            local selectedColor = colorCombo.CurrentText
            
            if selectedAngle and selectedAngle ~= "Bypass" and selectedColor and selectedColor ~= "" then
                -- Parse angle number from "Angle X" format
                local angleNum = tonumber(selectedAngle:match("Angle (%d+)"))
                if angleNum then
                    map[angleNum] = selectedColor
                end
            end
        end
    elseif mode == "Manual" then
        -- Manual mode: read from multiple UI ComboBoxes
        for rowIndex = 1, MAX_DISPLAYED_ANGLES do
            local angleNumCombo = itm["AngleNumber" .. rowIndex]
            local colorCombo = itm["AngleColor" .. rowIndex]
            
            if angleNumCombo and colorCombo then
                local selectedAngle = angleNumCombo.CurrentText
                local selectedColor = colorCombo.CurrentText
                
                -- Skip if "Bypass" is selected for angle number or color is empty
                if selectedAngle and selectedAngle ~= "Bypass" and selectedColor and selectedColor ~= "" then
                    -- Parse angle number from "Angle X" format
                    local angleNum = tonumber(selectedAngle:match("Angle (%d+)"))
                    if angleNum then
                        map[angleNum] = selectedColor
                    end
                end
            end
        end
    else
        -- Automatic mode: assign unique colors for all found angles (until ALL_COLORS is exhausted)
        map = buildAutomaticAngleColorMap()
    end
    
    return map
end

local function dumpAngleColorMapToConsole(angleColorMap)
    if not angleColorMap then
        return
    end

    local angles = {}
    for angle, _ in pairs(angleColorMap) do
        table.insert(angles, angle)
    end
    table.sort(angles)

    local colorToAngles = {}
    local usedColors = {}

    for _, angle in ipairs(angles) do
        local color = angleColorMap[angle]
        if color and color ~= "" then
            usedColors[color] = true
            if not colorToAngles[color] then
                colorToAngles[color] = {}
            end
            table.insert(colorToAngles[color], angle)
        end
    end

    local uniqueColorCount = 0
    for _, _ in pairs(usedColors) do
        uniqueColorCount = uniqueColorCount + 1
    end

    print("[Info] Angle -> Color mapping:")
    for _, angle in ipairs(angles) do
        print(string.format("[Info]   Angle %d -> %s", angle, tostring(angleColorMap[angle])))
    end

    local hasDuplicates = false
    for color, a in pairs(colorToAngles) do
        if #a > 1 then
            hasDuplicates = true
            table.sort(a)
            local parts = {}
            for _, v in ipairs(a) do
                table.insert(parts, tostring(v))
            end
            print(string.format("[Warning] Duplicate color '%s' for angles: %s", color, table.concat(parts, ", ")))
        end
    end

    if #angles > #ALL_COLORS then
        print(string.format("[Warning] %d angles detected but only %d colors available; repeats are unavoidable.", #angles, #ALL_COLORS))
    elseif hasDuplicates then
        print("[Warning] Duplicate colors detected; consider switching to Manual mode.")
    end

    print(string.format("[Info] %d angles mapped using %d unique colors.", #angles, uniqueColorCount))
end

local function applyColors(angleColorMap, statusLabel)
    if not angleColorMap then
        print("[Error] angleColorMap is nil")
        return
    end

    local coloredCount = 0
    debugPrint("applyColors: angleColorMap has", #angleColorMap, "entries (or is a map)")

    -- Print mapping before applying colors (helps debugging complex multicam setups)
    dumpAngleColorMapToConsole(angleColorMap)

    local function colorizeTrackItems(trackType)
        local trackCount = timeline:GetTrackCount(trackType)
        for trackIndex = 1, trackCount do
            local clips = timeline:GetItemListInTrack(trackType, trackIndex)
            if clips then
                for _, clip in ipairs(clips) do
                    local name = clip:GetName()
                    local angle = detectAngleFromName(name)
                    if angle and angleColorMap[angle] then
                    local ok = clip:SetClipColor(angleColorMap[angle])
                    if ok then
                        coloredCount = coloredCount + 1
                    end
                    end
                end
            end
        end
    end

    -- Colorize both video and audio items (when audio items come from multicam as well)
    colorizeTrackItems("video")
    colorizeTrackItems("audio")

    local msg = string.format("Colored %d clips (see Console for mapping)", coloredCount)
    print("[Info]", msg)
    if statusLabel then
        statusLabel.Text = msg
    end
end

----------------------------------------------------------------------
-- UI setup (UI Manager)
----------------------------------------------------------------------

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

local PRIMARY_COLOR = "#c0c0c0"
local BORDER_COLOR = "#3a6ea5"
local TEXT_COLOR = "#ebebeb"

local PRIMARY_ACTION_BUTTON_STYLE = [[
    QPushButton {
        border: 1px solid #2C6E49;
        max-height: 32px;
        border-radius: 10px;
        background-color: #4C956C;
        color: #FFFFFF;
        min-height: 26px;
        font-size: 14px;
        font-weight: bold;
    }
    QPushButton:hover {
        border: 1px solid ]] .. PRIMARY_COLOR .. [[;
        background-color: #61B15A;
    }
    QPushButton:pressed {
        border: 2px solid ]] .. PRIMARY_COLOR .. [[;
        background-color: #76C893;
    }
]]

local COMBOBOX_STYLE = [[
    QComboBox {
        border: 1px solid ]] .. BORDER_COLOR .. [[;
        border-radius: 5px;
        padding: 6px;
        background-color: #2A2A2A;
        color: ]] .. TEXT_COLOR .. [[;
        min-height: 24px;
    }
    QComboBox:hover {
        border-color: ]] .. PRIMARY_COLOR .. [[;
    }
]]

local SECTION_HEADER_STYLE = [[
    QLabel {
        color: ]] .. TEXT_COLOR .. [[;
        font-size: 16px;
        font-weight: bold;
        padding: 6px 0;
        letter-spacing: 0.5px;
    }
]]

local STATUS_LABEL_STYLE = [[
    QLabel {
        color: #c0c0c0;
        font-size: 13px;
        font-weight: bold;
        padding: 5px 0;
    }
]]

local ANGLE_GROUP_STYLE = [[
    QWidget {
        background-color: #1e1e1e;
        border-radius: 6px;
        padding: 5px;
    }
]]

-- Initial window size and centered position
local WINDOW_W, WINDOW_H = 400, 200
local fusionApp = fusion or fu
local screenW = fusionApp and fusionApp.GetPrefs and fusionApp:GetPrefs("Global.Main.RootWidth") or 1920
local screenH = fusionApp and fusionApp.GetPrefs and fusionApp:GetPrefs("Global.Main.RootHeight") or 1080
local WIN_X = math.max(0, math.floor((screenW - WINDOW_W) / 2))
local WIN_Y = math.max(0, math.floor((screenH - WINDOW_H) / 2))

local win = disp:AddWindow({
    ID = 'MulticamColorWin',
    WindowTitle = 'Multicam Angle Colorizer',
    Geometry = { WIN_X, WIN_Y, WINDOW_W, WINDOW_H },
    Spacing = 10,
    MinimumSize = {400, 200},

    ui:VGroup{
        ID = 'root',
        -- Mode selection
        ui:Label{ Text = "Mode", StyleSheet = SECTION_HEADER_STYLE },
        ui:ComboBox{
            ID = "ModeCombo",
            Weight = 1,
            StyleSheet = COMBOBOX_STYLE,
        },
        
        ui:VGap(8),
        
        -- Individual mode (single angle selection)
        ui:VGroup{
            ID = "IndividualGroup",
            Hidden = true,
            Spacing = 5,
            Weight = 1.0,
            ui:HGroup{
                Spacing = 10,
                StyleSheet = ANGLE_GROUP_STYLE,
                ui:ComboBox{
                    ID = "IndividualAngleCombo",
                    StyleSheet = COMBOBOX_STYLE,
                    Weight = 0.4,
                },
                ui:ComboBox{
                    ID = "IndividualColorCombo",
                    StyleSheet = COMBOBOX_STYLE,
                    Weight = 0.6,
                }
            },
        },
        
        -- Manual mode (multiple angles)
        ui:VGroup{
            ID = "AngleGroup",
            Hidden = true,
            Spacing = 5,
            Weight = 1.0,
            -- Angle rows (up to MAX_DISPLAYED_ANGLES angles)
            ui:VGroup{
                ID = "AngleRowsContainer",
                Spacing = 5,
                Weight = 1.0,
                -- Angle 1
                ui:HGroup{
                    ID = "AngleRow1",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber1",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor1",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
                -- Angle 2
                ui:HGroup{
                    ID = "AngleRow2",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber2",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor2",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
                -- Angle 3
                ui:HGroup{
                    ID = "AngleRow3",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber3",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor3",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
                -- Angle 4
                ui:HGroup{
                    ID = "AngleRow4",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber4",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor4",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
                -- Angle 5
                ui:HGroup{
                    ID = "AngleRow5",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber5",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor5",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
                -- Angle 6
                ui:HGroup{
                    ID = "AngleRow6",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber6",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor6",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
                -- Angle 7
                ui:HGroup{
                    ID = "AngleRow7",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber7",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor7",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
                -- Angle 8
                ui:HGroup{
                    ID = "AngleRow8",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber8",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor8",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
                -- Angle 9
                ui:HGroup{
                    ID = "AngleRow9",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber9",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor9",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
                -- Angle 10
                ui:HGroup{
                    ID = "AngleRow10",
                    Spacing = 10,
                    StyleSheet = ANGLE_GROUP_STYLE,
                    ui:ComboBox{
                        ID = "AngleNumber10",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.4,
                    },
                    ui:ComboBox{
                        ID = "AngleColor10",
                        StyleSheet = COMBOBOX_STYLE,
                        Weight = 0.6,
                    }
                },
            },
        },
        
        ui:VGap(8),
        
        -- Colorize button
        ui:Button{
            ID = "ColorizeBtn",
            Text = "Colorize",
            StyleSheet = PRIMARY_ACTION_BUTTON_STYLE,
        },
        
        -- Status label
        ui:Label{
            ID = "StatusLabel",
            StyleSheet = STATUS_LABEL_STYLE,
            Alignment = {AlignCenter = true},
        },
    },
})

local itm = win:GetItems()

-- Populate mode ComboBox
itm.ModeCombo:AddItems({"Automatic", "Manual", "Individual"})
itm.ModeCombo.CurrentText = "Manual"

-- Function to build angle options list
local function buildAngleOptionsList()
    local foundAngles = getFoundAnglesList()
    local angleOptions = {}
    
    -- Build list of angle options from found angles (format: "Angle 1", "Angle 2", etc.)
    for _, angle in ipairs(foundAngles) do
        table.insert(angleOptions, string.format("Angle %d", angle))
    end
    
    -- If no angles found, use default range 1-10
    if #angleOptions == 0 then
        for i = 1, MAX_DISPLAYED_ANGLES do
            table.insert(angleOptions, string.format("Angle %d", i))
        end
    end
    
    return angleOptions
end

-- Function to populate angle number ComboBoxes with found angles
local function populateAngleNumberCombos()
    local angleOptions = buildAngleOptionsList()
    
    -- Populate each angle number ComboBox
    for rowIndex = 1, MAX_DISPLAYED_ANGLES do
        local angleNumCombo = itm["AngleNumber" .. rowIndex]
        if angleNumCombo then
            -- Clear existing items
            angleNumCombo:Clear()
            -- Add "Bypass" option first
            angleNumCombo:AddItems({"Bypass"})
            -- Add found angle options
            if #angleOptions > 0 then
                angleNumCombo:AddItems(angleOptions)
            end
            
            -- Set default: use found angle at this row index, or row index if not found
            local foundAngles = getFoundAnglesList()
            if rowIndex <= #foundAngles then
                angleNumCombo.CurrentText = string.format("Angle %d", foundAngles[rowIndex])
            elseif rowIndex <= #angleOptions then
                angleNumCombo.CurrentText = angleOptions[rowIndex]
            else
                angleNumCombo.CurrentText = "Bypass"
            end
        end
    end
end

-- Function to populate Individual mode ComboBox
local function populateIndividualCombo()
    local angleOptions = buildAngleOptionsList()
    local individualCombo = itm.IndividualAngleCombo
    
    if individualCombo then
        individualCombo:Clear()
        individualCombo:AddItems({"Bypass"})
        if #angleOptions > 0 then
            individualCombo:AddItems(angleOptions)
            individualCombo.CurrentText = angleOptions[1]  -- Set first angle as default
        end
    end
end

-- Populate color ComboBoxes for Manual mode
for rowIndex = 1, MAX_DISPLAYED_ANGLES do
    local colorCombo = itm["AngleColor" .. rowIndex]
    if colorCombo then
        colorCombo:AddItems(ALL_COLORS)
        local def = DEFAULT_ANGLE_COLORS[rowIndex] or ALL_COLORS[1]
        colorCombo.CurrentText = def
    end
end

-- Populate Individual mode color ComboBox
if itm.IndividualColorCombo then
    itm.IndividualColorCombo:AddItems(ALL_COLORS)
    itm.IndividualColorCombo.CurrentText = ALL_COLORS[1]
end

-- Window sizing (absolute restore to initial height)
local initialGeometry = win.Geometry
local BASE_W = initialGeometry[3] or WINDOW_W
local BASE_H = initialGeometry[4] or WINDOW_H
local ANGLE_ROW_HEIGHT = 40  -- Approximate height per angle row

local function set_window_size(w, h)
    local g = win.Geometry
    local x = g[1]
    local y = g[2]
    local targetW = math.max(BASE_W, w)
    local targetH = math.max(BASE_H, h)

    -- Set Geometry first (position + size)
    win.Geometry = { x, y, targetW, targetH }
    win:RecalcLayout()
    win:Update()

    -- Some UIManager layouts won't "shrink" reliably after a larger layout (e.g. Manual mode).
    -- Force a real resize to the target size (double-pass nudge helps on some builds).
    pcall(function() win:Resize({ targetW, targetH + 5 }) end)
    pcall(function() win:Resize({ targetW, targetH }) end)
    win:RecalcLayout()
    win:Update()
end

local function set_window_height(h)
    local g = win.Geometry
    local w = g[3] or BASE_W
    set_window_size(w, h)
end

-- Function to update angle visibility
local function update_angle_visibility()
    local foundAngles = getFoundAnglesList()
    local totalAngles = #foundAngles
    local visibleCount = 0
    
    -- Update angle number ComboBoxes with current found angles
    populateAngleNumberCombos()
    
    -- Determine how many rows to show
    local rowsToShow = MAX_DISPLAYED_ANGLES
    if totalAngles > 0 and totalAngles <= MAX_DISPLAYED_ANGLES then
        -- If angles found and ≤ 10, show only that many rows
        rowsToShow = totalAngles
    elseif totalAngles == 0 then
        -- If no angles found, show all 10 rows for manual configuration
        rowsToShow = MAX_DISPLAYED_ANGLES
    end
    -- If totalAngles > 10, show all MAX_DISPLAYED_ANGLES rows (user will select in ComboBox)
    
    -- Show/hide rows based on calculated count
    for rowIndex = 1, MAX_DISPLAYED_ANGLES do
        local angleRow = itm["AngleRow" .. rowIndex]
        if angleRow then
            local shouldShow = (rowIndex <= rowsToShow)
            angleRow.Hidden = not shouldShow
            if shouldShow then
                visibleCount = visibleCount + 1
            end
        end
    end
    
    return visibleCount
end

-- Function to update mode state
local function update_mode_state()
    local mode = itm.ModeCombo.CurrentText
    local isAutomatic = (mode == "Automatic")
    local isManual = (mode == "Manual")
    local isIndividual = (mode == "Individual")
    
    -- Show/hide appropriate groups
    itm.IndividualGroup.Hidden = not isIndividual
    itm.AngleGroup.Hidden = not isManual
    
    if isIndividual then
        -- Individual mode: populate individual combo and set fixed window height
        populateIndividualCombo()
        set_window_size(WINDOW_W, 300)  -- Fixed size for individual mode
    elseif isManual then
        -- Manual mode: show angle rows
        local visibleCount = update_angle_visibility()
        local extraHeight = math.max(100, visibleCount * ANGLE_ROW_HEIGHT + 20)
        set_window_size(WINDOW_W, WINDOW_H + extraHeight)
    else
        -- Automatic mode: fixed compact size (prevents "stretched" layouts after manual)
        set_window_size(WINDOW_W, WINDOW_H)
    end
end

----------------------------------------------------------------------
-- Event handlers
----------------------------------------------------------------------

function win.On.ModeCombo.CurrentIndexChanged(ev)
    update_mode_state()
end

function win.On.ColorizeBtn.Clicked(ev)
    local angleColorMap = buildAngleColorMapFromUI(itm)
    applyColors(angleColorMap, itm.StatusLabel)
end

function win.On.MulticamColorWin.Close(ev)
    disp:ExitLoop()
end

-- Populate angle number ComboBoxes with found angles on timeline first
populateAngleNumberCombos()
populateIndividualCombo()

-- Initialize mode state (starts in Automatic mode)
update_mode_state()

-- Show UI
win:Show()
disp:RunLoop()
win:Hide()

