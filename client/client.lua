local isCapturing       = false
local isBrowsing        = false
local isPaused          = false
local isCancelled       = false
local isPreview         = false
local captureCamera     = nil
local captureGender     = 'male'
local captureRotOffset  = 0.0
local savedCameraAngles = {}
local activePreviewCamera = nil
local captureMode       = 'clothing'  -- 'clothing' | 'vehicle' | 'object'
local spawnedEntity     = nil
local vehicleColor      = { primary = 0, secondary = 0 }
local entitySpawnToken  = 0  -- increments each spawn request to cancel stale ones
-- Declared up here (not next to DrawHeadChromaMask) so the capture loops
-- defined earlier in the file write this local instead of a global.
local hideHeadActive    = false

-- Active headless/programmatic capture overrides and progress snapshot
local activeCaptureOpts = nil
local captureProgress   = nil

-- Synced image storage & CDN mapping cache from server
local RESOURCE_NAME = GetCurrentResourceName()
local imageMappingState = {
    storageType = 'local',
    baseUrl     = ('https://cfx-nui-%s/shots'):format(RESOURCE_NAME),
    format      = nil,
    pathLayout  = nil,
    mappings    = {},
    synced      = false,
}

-- Orbit-camera state. Declared up here so every section below (orbit camera,
-- capture start snapshot, NUI camera callbacks) shares the same values.
local orbitCam      = nil
local orbitAngleH   = 0.0
local orbitDist     = 1.2
local orbitCenter   = vector3(0.0, 0.0, 0.0)
local orbitFov      = 40.0
local orbitBaseDist = 1.2
local orbitRoll     = 0.0
local orbitCamZ     = 0.0   -- camera Z offset (center stays fixed, camera moves up/down)

local pedAppearance = {
    model = nil, coords = nil, heading = nil,
    components = {}, props = {},
    headBlend = nil, faceFeatures = {}, headOverlays = {},
}

-- ════════════════════════════════════════════════════════
-- FOLDER LAYOUTS & URL RESOLUTION
-- ════════════════════════════════════════════════════════

local LNS_COMPONENT_FOLDERS = {
    [0]  = 'components',
    [1]  = 'masks',
    [2]  = 'hair',
    [3]  = 'torsos',
    [4]  = 'legs',
    [5]  = 'bags',
    [6]  = 'shoes',
    [7]  = 'accessories',
    [8]  = 'undershirts',
    [9]  = 'armor',
    [10] = 'decals',
    [11] = 'tops',
}

local LNS_PROP_FOLDERS = {
    [0] = 'hats',
    [1] = 'glasses',
    [2] = 'ears',
    [6] = 'watches',
    [7] = 'bracelets',
}

-- ════════════════════════════════════════════════════════
-- HELPERS
-- ════════════════════════════════════════════════════════

local function HideHUD(state)
    DisplayRadar(not state)
    DisplayHud(not state)
end

local function SuppressWorld()
    SetVehicleDensityMultiplierThisFrame(0.0)
    SetPedDensityMultiplierThisFrame(0.0)
    SetRandomVehicleDensityMultiplierThisFrame(0.0)
    SetParkedVehicleDensityMultiplierThisFrame(0.0)
    SetScenarioPedDensityMultiplierThisFrame(0.0, 0.0)
    SetGarbageTrucks(false)
    SetRandomBoats(false)
    SetRandomTrains(false)
end

local GENDER_MODELS = { male = 'mp_m_freemode_01', female = 'mp_f_freemode_01' }

local function GetPedGender(ped)
    return (GetEntityModel(ped) == GetHashKey(GENDER_MODELS.female)) and 'female' or 'male'
end

local function OtherGender(gender)
    return gender == 'male' and 'female' or 'male'
end

local function AngleKey(cam)
    if cam == 'vehicle' or cam == 'object' then return cam end
    return captureGender .. ':' .. cam
end

local function GetSavedAngle(cam)
    local own = savedCameraAngles[AngleKey(cam)]
    if own or cam == 'vehicle' or cam == 'object' then return own end
    return savedCameraAngles[OtherGender(captureGender) .. ':' .. cam]
end

local function NormalizeFormat(fmt)
    local f = tostring(fmt or 'png'):lower()
    if f == 'jpeg' then f = 'jpg' end
    if f ~= 'png' and f ~= 'webp' and f ~= 'jpg' then f = 'png' end
    return f
end

-- Both PNG and WebP preserve chroma-removed alpha; only JPG forces PNG fallback.
local function SavedImageExt(fmtOverride, transparentOverride)
    local transp = transparentOverride
    if transp == nil then
        transp = (activeCaptureOpts and activeCaptureOpts.transparent ~= nil)
            and activeCaptureOpts.transparent
            or Customize.TransparentBg
    end
    local fmt = NormalizeFormat(
        fmtOverride
        or (activeCaptureOpts and activeCaptureOpts.format)
        or Customize.ScreenshotFormat
        or 'png'
    )
    if transp and fmt == 'jpg' then return 'png' end
    return fmt
end

local function GetPathLayout(layoutOverride)
    local raw = tostring(
        layoutOverride
        or (activeCaptureOpts and activeCaptureOpts.pathLayout)
        or Customize.PathLayout
        or 'lns'
    ):lower():gsub('%s+', '')
    if raw == 'uz' or raw == 'autoshot' or raw == 'legacy' then
        return 'autoshot'
    end
    return 'lns_appearance'
end

local function NormalizeImageKey(rawKey)
    if type(rawKey) ~= 'string' then return nil end
    local k = rawKey:gsub('^/+', ''):gsub('/+$', '')
    k = k:gsub('%.webp$', ''):gsub('%.png$', ''):gsub('%.jpeg$', ''):gsub('%.jpg$', '')
    if k == '' then return nil end
    return k
end

local function TattooFilename(gender, collection, overlay)
    return ('%s/tattoos/%s/%s'):format(gender, tostring(collection):lower(), tostring(overlay):lower())
end

local function BuildPhotoKey(gender, itemType, id, drawable, texture, layoutOverride)
    local layout = GetPathLayout(layoutOverride)
    local g = gender == 'female' and 'female' or 'male'

    if itemType == 'tattoo' then
        return TattooFilename(g, id, drawable)
    elseif itemType == 'vehicle' then
        return 'vehicles/' .. tostring(id)
    elseif itemType == 'object' then
        return 'objects/' .. tostring(id)
    end

    local numId = tonumber(id) or 0
    local numDraw = tonumber(drawable) or 0
    local numTex = tonumber(texture) or 0

    if layout == 'lns_appearance' then
        if itemType == 'component' then
            local folder = LNS_COMPONENT_FOLDERS[numId] or ('component_' .. numId)
            return ('%s/%s/%d/%d'):format(g, folder, numDraw, numTex)
        elseif itemType == 'prop' then
            local folder = LNS_PROP_FOLDERS[numId] or ('prop_' .. numId)
            return ('%s/%s/%d/%d'):format(g, folder, numDraw, numTex)
        elseif itemType == 'overlay' then
            return ('%s/overlays/%d/%d'):format(g, numId, numDraw)
        end
    end

    -- Default 'autoshot' layout
    if itemType == 'component' then
        return numTex > 0
            and ('%s/%d/%d_%d'):format(g, numId, numDraw, numTex)
            or  ('%s/%d/%d'):format(g, numId, numDraw)
    elseif itemType == 'prop' then
        return numTex > 0
            and ('%s/prop_%d/%d_%d'):format(g, numId, numDraw, numTex)
            or  ('%s/prop_%d/%d'):format(g, numId, numDraw)
    elseif itemType == 'overlay' then
        return ('%s/overlay_%d/%d'):format(g, numId, numDraw)
    end

    return nil
end

local function ResolveKeyURL(rawKey, extOverride)
    local key = NormalizeImageKey(rawKey)
    if not key then return nil end

    if imageMappingState.mappings and imageMappingState.mappings[key] then
        return imageMappingState.mappings[key]
    end

    local base = imageMappingState.baseUrl
    if base and base ~= '' then
        base = base:gsub('/+$', '')
        return ('%s/%s.%s'):format(base, key, extOverride or SavedImageExt())
    end

    return nil
end

local function ResolvePhotoURL(gender, itemType, id, drawable, texture, opts, mappedOnly)
    local preferredLayout = opts and opts.pathLayout
    local ext = opts and opts.format and NormalizeFormat(opts.format) or SavedImageExt()
    local primaryKey = BuildPhotoKey(gender, itemType, id, drawable, texture, preferredLayout)
    if not primaryKey then return nil end

    if imageMappingState.mappings and imageMappingState.mappings[primaryKey] then
        return imageMappingState.mappings[primaryKey]
    end

    -- Check alternate layout key in synced mappings so screenshots remain findable
    -- regardless of which PathLayout was active when they were shot.
    if not preferredLayout then
        local altLayout = GetPathLayout() == 'lns_appearance' and 'autoshot' or 'lns_appearance'
        local altKey = BuildPhotoKey(gender, itemType, id, drawable, texture, altLayout)
        if altKey and imageMappingState.mappings and imageMappingState.mappings[altKey] then
            return imageMappingState.mappings[altKey]
        end
    end

    if mappedOnly then return nil end
    return ResolveKeyURL(primaryKey, ext)
end

-- ════════════════════════════════════════════════════════
-- SERVER MAPPING SYNC EVENTS
-- ════════════════════════════════════════════════════════

RegisterNetEvent('uz_autoshot:client:syncMappings', function(data)
    if type(data) ~= 'table' then return end
    imageMappingState.storageType = data.storageType or imageMappingState.storageType
    imageMappingState.baseUrl     = data.baseUrl ~= nil and data.baseUrl or imageMappingState.baseUrl
    imageMappingState.format      = data.format or imageMappingState.format
    imageMappingState.pathLayout  = data.pathLayout or imageMappingState.pathLayout
    imageMappingState.mappings    = type(data.mappings) == 'table' and data.mappings or {}
    imageMappingState.synced      = true
    TriggerEvent('uz_autoshot:client:mappingsChanged', imageMappingState)
end)

RegisterNetEvent('uz_autoshot:client:mappingUpdated', function(key, url)
    if type(key) ~= 'string' or type(url) ~= 'string' then return end
    imageMappingState.mappings[key] = url
    TriggerEvent('uz_autoshot:client:mappingsChanged', imageMappingState, { [key] = url })
end)

RegisterNetEvent('uz_autoshot:client:mappingsPatch', function(patch)
    if type(patch) ~= 'table' then return end
    for k, v in pairs(patch) do
        imageMappingState.mappings[k] = v
    end
    TriggerEvent('uz_autoshot:client:mappingsChanged', imageMappingState, patch)
end)

CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(250) end
    Wait(500)
    TriggerServerEvent('uz_autoshot:server:requestMappings')
end)

-- ════════════════════════════════════════════════════════
-- VEHICLES & MODEL HELPERS
-- ════════════════════════════════════════════════════════

local resolvedVehicleCategories = nil

local VehicleClassNames = {
    [0]  = 'Compacts',      [1]  = 'Sedans',        [2]  = 'SUVs',
    [3]  = 'Coupes',        [4]  = 'Muscle',        [5]  = 'Sports Classics',
    [6]  = 'Sports',        [7]  = 'Super',         [8]  = 'Motorcycles',
    [9]  = 'Off-Road',      [10] = 'Industrial',    [11] = 'Utility',
    [12] = 'Vans',          [13] = 'Cycles',        [14] = 'Boats',
    [15] = 'Helicopters',   [16] = 'Planes',        [17] = 'Service',
    [18] = 'Emergency',     [19] = 'Military',      [20] = 'Commercial',
    [21] = 'Trains',        [22] = 'Open Wheel',
}

local function GetVehicleCategories()
    if resolvedVehicleCategories then return resolvedVehicleCategories end

    local cfg = Customize.VehicleCategories
    if type(cfg) == 'table' then
        resolvedVehicleCategories = cfg
        return cfg
    end

    local models = GetAllVehicleModels()
    local byClass = {}
    if models then
        for _, modelName in ipairs(models) do
            local hash = GetHashKey(modelName)
            local classId = GetVehicleClassFromName(hash)
            local className = VehicleClassNames[classId] or ('Class ' .. classId)
            if not byClass[classId] then
                byClass[classId] = { id = classId, name = className, models = {} }
            end
            byClass[classId].models[#byClass[classId].models + 1] = modelName
        end
    end

    local list = {}
    local classIds = {}
    for id in pairs(byClass) do classIds[#classIds + 1] = id end
    table.sort(classIds)

    for _, classId in ipairs(classIds) do
        local group = byClass[classId]
        table.sort(group.models)
        for _, modelName in ipairs(group.models) do
            list[#list + 1] = { model = modelName, label = modelName, category = group.name }
        end
    end

    resolvedVehicleCategories = list
    return list
end

local function LoadModel(modelHash)
    RequestModel(modelHash)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(modelHash) and GetGameTimer() < timeout do
        Wait(10)
    end
    return HasModelLoaded(modelHash)
end

-- ════════════════════════════════════════════════════════
-- CAPTURE CAMERA
-- ════════════════════════════════════════════════════════

local function CreateCaptureCamera(entity, preset, presetName)
    local pedPos = GetEntityCoords(entity)
    local saved  = presetName and GetSavedAngle(presetName)
    local camX, camY, camZ, fov, lookZ, roll

    if saved then
        local zP = saved.zPos or preset.zPos
        local cZ = saved.camZ or 0.0
        camX  = pedPos.x + saved.dist * math.sin(saved.angleH)
        camY  = pedPos.y - saved.dist * math.cos(saved.angleH)
        camZ  = pedPos.z + zP + cZ
        fov   = saved.fov or preset.fov
        lookZ = pedPos.z + zP
        roll  = saved.roll or 0.0
    elseif preset.defaultAngleH then
        local dist = preset.dist or 1.2
        local aH   = math.rad(preset.defaultAngleH)
        local cZ   = preset.defaultCamZ or 0.0
        camX  = pedPos.x + dist * math.sin(aH)
        camY  = pedPos.y - dist * math.cos(aH)
        camZ  = pedPos.z + preset.zPos + cZ
        fov   = preset.fov
        lookZ = pedPos.z + preset.zPos
        roll  = preset.defaultRoll or 0.0
    else
        local rotZ = preset.rotation.z + captureRotOffset
        SetEntityRotation(entity, preset.rotation.x, preset.rotation.y, rotZ, 2, false)
        Wait(50)
        local fwd = GetEntityForwardVector(entity)
        local dist = preset.dist or 1.2
        camX  = pedPos.x - fwd.x * dist
        camY  = pedPos.y - fwd.y * dist
        camZ  = pedPos.z - fwd.z + preset.zPos
        fov   = preset.fov
        lookZ = pedPos.z + preset.zPos
        roll  = 0.0
    end

    local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', camX, camY, camZ, 0.0, 0.0, 0.0, fov, false, 0)

    local dx = pedPos.x - camX
    local dy = pedPos.y - camY
    local dz = lookZ - camZ
    local dist2d = math.sqrt(dx * dx + dy * dy)
    local pitch  = math.deg(math.atan(dz, dist2d))
    local heading = -math.deg(math.atan(dx, dy))
    SetCamRot(cam, pitch, roll, heading, 2)

    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    return cam
end

local function DestroyCamera()
    if captureCamera then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(captureCamera, false)
        captureCamera = nil
    end
end

-- ════════════════════════════════════════════════════════
-- GREEN SCREEN + STUDIO LIGHTING
-- ════════════════════════════════════════════════════════

local function DrawQuad(x1,y1,z1, x2,y2,z2, x3,y3,z3, x4,y4,z4, r,g,b,a)
    DrawPoly(x1,y1,z1, x2,y2,z2, x3,y3,z3, r,g,b,a)
    DrawPoly(x3,y3,z3, x4,y4,z4, x1,y1,z1, r,g,b,a)
    DrawPoly(x3,y3,z3, x2,y2,z2, x1,y1,z1, r,g,b,a)
    DrawPoly(x1,y1,z1, x4,y4,z4, x3,y3,z3, r,g,b,a)
end

local function DrawGreenScreenAndLights(entity)
    local pos = GetEntityCoords(entity)
    local gs
    local lights
    if captureMode == 'vehicle' then
        gs     = Customize.VehicleGreenScreen or Customize.GreenScreen
        lights = Customize.VehicleStudioLights or Customize.StudioLights
    elseif captureMode == 'object' then
        gs     = Customize.ObjectGreenScreen or Customize.GreenScreen
        lights = Customize.StudioLights
    else
        gs     = Customize.GreenScreen
        lights = Customize.StudioLights
    end

    local chromaPreset = (activeCaptureOpts and activeCaptureOpts.chromaKey) or Customize.ChromaKeyColor
    local r, g, b
    if chromaPreset == 'green' then
        r, g, b = 0, 177, 64
    elseif chromaPreset == 'magenta' then
        r, g, b = 255, 0, 255
    else
        r, g, b = Customize.GreenScreen.color.r, Customize.GreenScreen.color.g, Customize.GreenScreen.color.b
    end

    local hw = gs.width  * 0.5
    local hd = gs.depth  * 0.5
    local fz = pos.z + (gs.floorOffset or -3.0)
    local cz = fz + gs.height

    local x1, y1 = pos.x - hw, pos.y - hd
    local x2, y2 = pos.x + hw, pos.y - hd
    local x3, y3 = pos.x - hw, pos.y + hd
    local x4, y4 = pos.x + hw, pos.y + hd

    DrawQuad(x1,y1,fz, x2,y2,fz, x2,y2,cz, x1,y1,cz, r,g,b,255)
    DrawQuad(x4,y4,fz, x3,y3,fz, x3,y3,cz, x4,y4,cz, r,g,b,255)
    DrawQuad(x3,y3,fz, x1,y1,fz, x1,y1,cz, x3,y3,cz, r,g,b,255)
    DrawQuad(x2,y2,fz, x4,y4,fz, x4,y4,cz, x2,y2,cz, r,g,b,255)
    DrawQuad(x1,y1,fz, x2,y2,fz, x4,y4,fz, x3,y3,fz, r,g,b,255)
    DrawQuad(x3,y3,cz, x4,y4,cz, x2,y2,cz, x1,y1,cz, r,g,b,255)

    for _, light in ipairs(lights) do
        DrawLightWithRange(
            pos.x + light.offset.x,
            pos.y + light.offset.y,
            pos.z + light.offset.z,
            255, 255, 255,
            light.range,
            light.intensity
        )
    end
end

-- ════════════════════════════════════════════════════════
-- CROP OVERLAY (preview only — shows final image bounds)
-- ════════════════════════════════════════════════════════

local cropBars = nil

local function ComputeCropBars()
    local tw = Customize.ScreenshotWidth or 0
    local th = Customize.ScreenshotHeight or 0
    if tw <= 0 or th <= 0 then cropBars = false return end

    local sw, sh = GetActiveScreenResolution()
    local screenAspect = sw / sh
    local targetAspect = tw / th

    if screenAspect > targetAspect then
        local barW = (1.0 - targetAspect / screenAspect) / 2.0
        cropBars = { mode = 'v', x1 = barW / 2.0, x2 = 1.0 - barW / 2.0, size = barW }
    elseif screenAspect < targetAspect then
        local barH = (1.0 - screenAspect / targetAspect) / 2.0
        cropBars = { mode = 'h', y1 = barH / 2.0, y2 = 1.0 - barH / 2.0, size = barH }
    else
        cropBars = false
    end
end

local function DrawCropOverlay()
    if cropBars == nil then ComputeCropBars() end
    if not cropBars then return end

    if cropBars.mode == 'v' then
        DrawRect(cropBars.x1, 0.5, cropBars.size, 1.0, 0, 0, 0, 150)
        DrawRect(cropBars.x2, 0.5, cropBars.size, 1.0, 0, 0, 0, 150)
    else
        DrawRect(0.5, cropBars.y1, 1.0, cropBars.size, 0, 0, 0, 150)
        DrawRect(0.5, cropBars.y2, 1.0, cropBars.size, 0, 0, 0, 150)
    end
end

-- ════════════════════════════════════════════════════════
-- ORBIT CAMERA
-- ════════════════════════════════════════════════════════

local function UpdateOrbitCamera()
    if not orbitCam then return end
    local camX = orbitCenter.x + orbitDist * math.sin(orbitAngleH)
    local camY = orbitCenter.y - orbitDist * math.cos(orbitAngleH)
    local camZ = orbitCenter.z + orbitCamZ
    SetCamCoord(orbitCam, camX, camY, camZ)

    local dx = orbitCenter.x - camX
    local dy = orbitCenter.y - camY
    local dz = orbitCenter.z - camZ
    local dist2d = math.sqrt(dx * dx + dy * dy)
    local pitch  = math.deg(math.atan(dz, dist2d))
    local heading = -math.deg(math.atan(dx, dy))

    SetCamRot(orbitCam, pitch, orbitRoll, heading, 2)
end

local function SetOrbitPreset(presetName)
    if not orbitCam then return end
    local preset = Customize.CameraPresets[presetName]
    if not preset then return end

    local pedPos = GetEntityCoords(PlayerPedId())
    orbitCenter   = vector3(pedPos.x, pedPos.y, pedPos.z + preset.zPos)
    orbitBaseDist = preset.dist or 1.2
    orbitDist     = orbitBaseDist
    orbitFov      = preset.fov
    orbitCamZ     = preset.defaultCamZ or 0.0
    orbitRoll     = preset.defaultRoll or 0.0
    if preset.defaultAngleH then
        orbitAngleH = math.rad(preset.defaultAngleH)
    end
    SetCamFov(orbitCam, orbitFov)
    UpdateOrbitCamera()
end

local function CreateOrbitCamera(ped, presetName)
    local pName = presetName or (Customize.Categories[1] and Customize.Categories[1].camera) or 'tops'
    local preset = Customize.CameraPresets[pName] or Customize.CameraPresets['tops']
    local pedPos = GetEntityCoords(ped)
    activePreviewCamera = pName

    orbitCenter   = vector3(pedPos.x, pedPos.y, pedPos.z + preset.zPos)
    orbitBaseDist = preset.dist or 1.2
    orbitDist     = orbitBaseDist
    orbitFov      = preset.fov
    if preset.defaultAngleH then
        orbitAngleH = math.rad(preset.defaultAngleH)
    else
        orbitAngleH = math.rad((GetEntityHeading(ped) + 180.0) % 360.0)
    end
    orbitCamZ     = preset.defaultCamZ or 0.0
    orbitRoll     = preset.defaultRoll or 0.0

    local camX = orbitCenter.x + orbitDist * math.sin(orbitAngleH)
    local camY = orbitCenter.y - orbitDist * math.cos(orbitAngleH)

    orbitCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        camX, camY, orbitCenter.z, 0.0, 0.0, 0.0, orbitFov, false, 0)
    SetCamActive(orbitCam, true)
    RenderScriptCams(true, false, 0, true, true)
    UpdateOrbitCamera()
end

local function DestroyOrbitCamera()
    if orbitCam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(orbitCam, false)
        orbitCam = nil
    end
end

-- ════════════════════════════════════════════════════════
-- TEXTURE LOADING
-- ════════════════════════════════════════════════════════

local function ForceHighQuality()
    OverrideLodscaleThisFrame(1.0)
    SetHdArea(0.0, 0.0, -150.0, 50.0)
    SetFocusPosAndVel(0.0, 0.0, -150.0, 0.0, 0.0, 0.0)
end

local function WaitForClothingLoaded(ped, componentId, drawableId, textureId)
    SetPedPreloadVariationData(ped, componentId, drawableId, textureId)
    local timeout = GetGameTimer() + 800
    while not HasPedPreloadVariationDataFinished(ped) and GetGameTimer() < timeout do
        Wait(0)
    end
    SetPedComponentVariation(ped, componentId, drawableId, textureId, 0)
    ReleasePedPreloadVariationData(ped)
    ForceHighQuality()
    SetEntityLodDist(ped, 10000)
    Wait(0)
    ForceHighQuality()
    Wait(0)
end

local function WaitForPropLoaded(ped, propId, drawableId, textureId)
    SetPedPropIndex(ped, propId, drawableId, textureId, true)
    Wait(0)
    local timeout = GetGameTimer() + 2000
    while GetPedPropIndex(ped, propId) ~= drawableId and GetGameTimer() < timeout do
        Wait(10)
    end

    local coords = GetEntityCoords(ped)
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    local streamTimeout = GetGameTimer() + 1500
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < streamTimeout do
        Wait(10)
    end
    Wait(Customize.TextureLoadWait)
end

-- ════════════════════════════════════════════════════════
-- PAUSE / RESUME
-- ════════════════════════════════════════════════════════

local function WaitForResume()
    if not isPaused then return end
    local hideUi = activeCaptureOpts and activeCaptureOpts.hideOverlay == true
    if not hideUi then
        SendNUIMessage({ type = 'setCapturePaused', paused = true })
        SetNuiFocus(true, true)
    end

    while isPaused and not isCancelled do Wait(200) end

    if not isCancelled and not hideUi then
        SendNUIMessage({ type = 'setCapturePaused', paused = false })
        SetNuiFocus(false, false)
        Wait(50)
    end
end

-- ════════════════════════════════════════════════════════
-- CAPTURE & UPLOAD
-- ════════════════════════════════════════════════════════

local pendingUploads     = {}
local pendingCount       = 0
local nextUploadId       = 0
local UPLOAD_ACK_TIMEOUT = 90000

RegisterNetEvent('uz_autoshot:client:captureProcessed', function(uploadId)
    if pendingUploads[uploadId] then
        pendingUploads[uploadId] = nil
        pendingCount = pendingCount - 1
    end
end)

local function WaitForPendingUploads(limit)
    while pendingCount > limit and not isCancelled do
        local now = GetGameTimer()
        for id, sentAt in pairs(pendingUploads) do
            if now - sentAt > UPLOAD_ACK_TIMEOUT then
                pendingUploads[id] = nil
                pendingCount = pendingCount - 1
                print(('^3[uz_AutoShot]^0 Upload #%d not confirmed by server after %ds, moving on'):format(id, UPLOAD_ACK_TIMEOUT // 1000))
            end
        end
        if pendingCount > limit then Wait(50) end
    end
end

local serverStatus = nil
RegisterNetEvent('uz_autoshot:client:pong', function(status) serverStatus = status end)

local function ServerReady(opts)
    serverStatus = nil
    local pingPayload = {
        format = (opts and opts.format) or Customize.ScreenshotFormat or 'png',
        transparent = (opts and opts.transparent ~= nil) and opts.transparent or Customize.TransparentBg,
    }
    TriggerServerEvent('uz_autoshot:server:ping', pingPayload)
    local timeout = GetGameTimer() + 5000
    while serverStatus == nil and GetGameTimer() < timeout do Wait(50) end

    local reason
    if serverStatus == nil then
        reason = 'Server side not responding. Check the server console.'
    elseif not serverStatus.ok then
        reason = serverStatus.reason or 'Server refused captures.'
    else
        return true, nil
    end

    print('^1[uz_AutoShot]^0 ' .. reason)
    if not (opts and opts.silentNotify) then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('uz_AutoShot: ' .. reason)
        EndTextCommandThefeedPostTicker(false, false)
    end
    return false, reason
end

local function RequestGameScreenshot(opts, cb)
    if GetResourceState('screencapture') == 'started' then
        exports.screencapture:requestScreenshot(opts, cb)
    elseif GetResourceState('screenshot-basic') == 'started' then
        exports['screenshot-basic']:requestScreenshot(opts, cb)
    else
        cb(nil)
    end
end

local function ShouldSkipKey(key)
    if not (activeCaptureOpts and activeCaptureOpts.skipExisting) then return false end
    return imageMappingState.mappings and imageMappingState.mappings[key] ~= nil
end

local function CaptureAndUpload(filename)
    WaitForPendingUploads((Customize.MaxPendingUploads or 2) - 1)
    if isCancelled then return false end

    ForceHighQuality()

    local wantTransp = (activeCaptureOpts and activeCaptureOpts.transparent ~= nil)
        and activeCaptureOpts.transparent
        or Customize.TransparentBg
    local wantWidth  = (activeCaptureOpts and activeCaptureOpts.width) or Customize.ScreenshotWidth or 0
    local wantHeight = (activeCaptureOpts and activeCaptureOpts.height) or Customize.ScreenshotHeight or 0
    local outFormat  = SavedImageExt(activeCaptureOpts and activeCaptureOpts.format, wantTransp)
    local quality    = (activeCaptureOpts and activeCaptureOpts.quality) or Customize.ScreenshotQuality or 0.85
    local chromaKey  = (activeCaptureOpts and activeCaptureOpts.chromaKey) or Customize.ChromaKeyColor or 'green'

    -- Capture lossless PNG whenever the server needs to decode RGBA (chroma key, resize, or WebP encoding)
    local needPngCapture = wantTransp or (wantWidth > 0 and wantHeight > 0) or outFormat == 'webp' or outFormat == 'png'
    local captureEncoding = needPngCapture and 'png' or 'jpg'

    local opts = { encoding = captureEncoding }
    if captureEncoding ~= 'png' then
        opts.quality = quality
    end

    local done, base64 = false, nil
    RequestGameScreenshot(opts, function(data)
        base64 = data
        done = true
    end)

    local timeout = GetGameTimer() + 10000
    while not done and GetGameTimer() < timeout do Wait(50) end

    if not done then
        print('^3[uz_AutoShot]^0 Capture skipped (' .. filename .. '): screenshot resource did not respond within 10s')
        return false
    end
    if not base64 or base64 == '' then
        print('^3[uz_AutoShot]^0 Capture skipped (' .. filename .. '): screenshot resource returned no image data')
        return false
    end

    nextUploadId = nextUploadId + 1
    pendingUploads[nextUploadId] = GetGameTimer()
    pendingCount = pendingCount + 1

    TriggerLatentServerEvent('uz_autoshot:server:processCapture', Customize.LatentRate or 8000000, {
        id           = nextUploadId,
        filename     = filename,
        format       = captureEncoding,
        outputFormat = outFormat,
        quality      = quality,
        transparent  = wantTransp and true or false,
        chromaKey    = chromaKey,
        width        = wantWidth,
        height       = wantHeight,
        imageData    = base64,
    })
    return true
end

local function SendProgress(current, total, category, phase)
    captureProgress = {
        current  = current,
        total    = total,
        category = category,
        phase    = phase or captureMode,
        gender   = captureGender,
    }
    TriggerEvent('uz_autoshot:client:progress', captureProgress)
    if activeCaptureOpts and type(activeCaptureOpts.onProgress) == 'function' then
        pcall(activeCaptureOpts.onProgress, current, total, category, phase or captureMode)
    end
    if not (activeCaptureOpts and activeCaptureOpts.hideOverlay) then
        SendNUIMessage({ type = 'captureProgress', current = current, total = total, category = category })
    end
end

local batchCounter = 0
local function ThrottledWait()
    batchCounter = batchCounter + 1
    if batchCounter % Customize.GCInterval == 0 then collectgarbage('collect') end
    if batchCounter % Customize.BatchSize == 0 then Wait(Customize.BatchPauseWait) end
end

-- ════════════════════════════════════════════════════════
-- PED APPEARANCE — Save / Restore
-- ════════════════════════════════════════════════════════

local APPEARANCE_PROVIDERS = { 'LNS_Appearance', 'illenium-appearance', 'fivem-appearance' }

local function GetAppearanceProvider()
    for _, name in ipairs(APPEARANCE_PROVIDERS) do
        if GetResourceState(name) == 'started' then return name end
    end
    return nil
end

local function ReadHeadBlend(ped)
    local shapeFirst, shapeSecond, shapeThird, skinFirst, skinSecond, skinThird, shapeMix, skinMix, thirdMix =
        Citizen.InvokeNative(0x2746BD9D88C5C5D0, ped,
            Citizen.PointerValueIntInitialized(0), Citizen.PointerValueIntInitialized(0), Citizen.PointerValueIntInitialized(0),
            Citizen.PointerValueIntInitialized(0), Citizen.PointerValueIntInitialized(0), Citizen.PointerValueIntInitialized(0),
            Citizen.PointerValueFloatInitialized(0), Citizen.PointerValueFloatInitialized(0), Citizen.PointerValueFloatInitialized(0))
    if not shapeFirst then return nil end
    local function mix(v) return math.max(0.0, math.min(1.0, (tonumber(v) or 0.0) + 0.0)) end
    return {
        shapeFirst = shapeFirst, shapeSecond = shapeSecond, shapeThird = shapeThird or 0,
        skinFirst  = skinFirst,  skinSecond  = skinSecond,  skinThird  = skinThird or 0,
        shapeMix = mix(shapeMix), skinMix = mix(skinMix), thirdMix = mix(thirdMix),
    }
end

local function SaveFullAppearance(ped)
    pedAppearance.model   = GetEntityModel(ped)
    pedAppearance.coords  = GetEntityCoords(ped)
    pedAppearance.heading = GetEntityHeading(ped)

    pedAppearance.components = {}
    for i = 0, 11 do
        pedAppearance.components[i] = {
            drawable = GetPedDrawableVariation(ped, i),
            texture  = GetPedTextureVariation(ped, i),
            palette  = GetPedPaletteVariation(ped, i),
        }
    end

    pedAppearance.props = {}
    for i = 0, 7 do
        pedAppearance.props[i] = {
            drawable = GetPedPropIndex(ped, i),
            texture  = GetPedPropTextureIndex(ped, i),
        }
    end

    pedAppearance.headBlend = ReadHeadBlend(ped)

    pedAppearance.faceFeatures = {}
    for i = 0, 19 do pedAppearance.faceFeatures[i] = GetPedFaceFeature(ped, i) end

    pedAppearance.headOverlays = {}
    for i = 0, 12 do
        local _, value, colourType, firstColour, secondColour, opacity = GetPedHeadOverlayData(ped, i)
        pedAppearance.headOverlays[i] = {
            value = value, colourType = colourType,
            firstColour = firstColour, secondColour = secondColour, opacity = opacity,
        }
    end

    pedAppearance.hair     = { color = GetPedHairColor(ped), highlight = GetPedHairHighlightColor(ped) }
    pedAppearance.eyeColor = GetPedEyeColor(ped)

    pedAppearance.provider = GetAppearanceProvider()
    pedAppearance.full     = nil
    if pedAppearance.provider then
        local ok, full = pcall(function() return exports[pedAppearance.provider]:getPedAppearance(ped) end)
        if ok and type(full) == 'table' then pedAppearance.full = full end
    end
end

local function RestoreFullAppearance()
    local model = pedAppearance.model
    if not model then return end

    if LoadModel(model) then
        SetPlayerModel(PlayerId(), model)
        Wait(150)
        SetModelAsNoLongerNeeded(model)
        Wait(150)
    end

    local ped = PlayerPedId()

    if pedAppearance.coords then
        local x, y, z = pedAppearance.coords.x, pedAppearance.coords.y, pedAppearance.coords.z

        FreezeEntityPosition(ped, true)
        SetEntityCollision(ped, false, false)
        SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
        if pedAppearance.heading then
            SetEntityHeading(ped, pedAppearance.heading)
        end

        SetFocusPosAndVel(x, y, z, 0.0, 0.0, 0.0)
        RequestCollisionAtCoord(x, y, z)
        NewLoadSceneStart(x, y, z, 100.0, 0)

        local timeout = GetGameTimer() + 5000
        while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < timeout do
            RequestCollisionAtCoord(x, y, z)
            Wait(0)
        end

        if IsNewLoadSceneActive() then NewLoadSceneStop() end
        ClearFocus()
    end

    local restored = false
    local provider = pedAppearance.provider
    if pedAppearance.full and provider and GetResourceState(provider) == 'started' then
        restored = pcall(function() exports[provider]:setPedAppearance(ped, pedAppearance.full) end)
        if not restored then
            print('^3[uz_AutoShot]^0 ' .. provider .. ' setPedAppearance failed, restoring with natives')
        end
    end

    if not restored then
        if pedAppearance.headBlend then
            local hb = pedAppearance.headBlend
            SetPedHeadBlendData(ped, hb.shapeFirst, hb.shapeSecond, hb.shapeThird, hb.skinFirst, hb.skinSecond, hb.skinThird, hb.shapeMix, hb.skinMix, hb.thirdMix, false)
        end

        for i = 0, 19 do
            if pedAppearance.faceFeatures[i] then SetPedFaceFeature(ped, i, pedAppearance.faceFeatures[i]) end
        end
        for i = 0, 12 do
            local o = pedAppearance.headOverlays[i]
            if o and o.value then
                SetPedHeadOverlay(ped, i, o.value, (o.opacity or 1.0) + 0.0)
                if o.value ~= 255 and o.colourType and o.colourType > 0 then
                    SetPedHeadOverlayColor(ped, i, o.colourType, o.firstColour or 0, o.secondColour or 0)
                end
            end
        end
        for i = 0, 11 do
            local comp = pedAppearance.components[i]
            if comp then SetPedComponentVariation(ped, i, comp.drawable, comp.texture, comp.palette) end
        end
        for i = 0, 7 do
            local prop = pedAppearance.props[i]
            if prop then
                if prop.drawable == -1 then ClearPedProp(ped, i)
                else SetPedPropIndex(ped, i, prop.drawable, prop.texture, true) end
            end
        end
        if pedAppearance.hair then SetPedHairColor(ped, pedAppearance.hair.color, pedAppearance.hair.highlight) end
        if pedAppearance.eyeColor then SetPedEyeColor(ped, pedAppearance.eyeColor) end
    end

    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    ClearPedTasksImmediately(ped)
    Wait(100)
    ClearPedTasks(ped)
    SetPlayerControl(PlayerId(), true, 0)
end

-- ════════════════════════════════════════════════════════
-- CAPTURE PED SETUP
-- ════════════════════════════════════════════════════════

local function SetupCapturePed(modelHash)
    if not LoadModel(modelHash) then return PlayerPedId() end

    SetPlayerModel(PlayerId(), modelHash)
    Wait(150)
    SetModelAsNoLongerNeeded(modelHash)
    Wait(150)

    local ped = PlayerPedId()
    local face = modelHash == GetHashKey(GENDER_MODELS.female) and 21 or 0
    SetPedHeadBlendData(ped, face, 0, 0, 0, 0, 0, 0.0, 0.0, 0.0, false)
    SetEntityCoordsNoOffset(ped, Customize.StudioCoords.x, Customize.StudioCoords.y, Customize.StudioCoords.z, false, false, false)
    SetEntityHeading(ped, Customize.StudioHeading)
    FreezeEntityPosition(ped, true)
    Wait(50)
    SetPlayerControl(PlayerId(), false, 0)
    return ped
end

local function ResetPedForCategory(ped, visibleComponents, componentOverrides)
    SetPedDefaultComponentVariation(ped)
    Wait(150)

    for _, p in ipairs({0, 1, 2, 6, 7}) do ClearPedProp(ped, p) end

    SetPlayerControl(PlayerId(), false, 0)
    FreezeEntityPosition(ped, true)

    local visSet = {}
    if visibleComponents then
        for _, id in ipairs(visibleComponents) do visSet[id] = true end
    end

    local overrides = componentOverrides or {}

    for i = 0, 11 do
        if overrides[i] then
            SetPedComponentVariation(ped, i, overrides[i], 0, 0)
        elseif visSet[i] then
            SetPedComponentVariation(ped, i, 0, 0, 0)
        else
            SetPedComponentVariation(ped, i, -1, 0, 0)
        end
    end
end

-- ════════════════════════════════════════════════════════
-- VEHICLE / OBJECT SPAWN HELPERS
-- ════════════════════════════════════════════════════════

local function SpawnStudioVehicle(modelName, token)
    local hash = GetHashKey(modelName)
    if not LoadModel(hash) then return nil end
    if token and token ~= entitySpawnToken then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end

    local sx, sy, sz = Customize.StudioCoords.x, Customize.StudioCoords.y, Customize.StudioCoords.z
    local playerPos = GetEntityCoords(PlayerPedId())
    local veh = CreateVehicle(hash, playerPos.x, playerPos.y, playerPos.z, Customize.StudioHeading, false, false)
    if not DoesEntityExist(veh) then return nil end

    SetEntityAsMissionEntity(veh, true, true)
    SetModelAsNoLongerNeeded(hash)
    SetEntityCollision(veh, false, false)
    FreezeEntityPosition(veh, true)

    SetEntityCoordsNoOffset(veh, sx, sy, sz + 1.0, false, false, false)
    SetEntityHeading(veh, Customize.StudioHeading)
    FreezeEntityPosition(veh, true)
    SetVehicleEngineOn(veh, false, true, true)
    SetVehicleHandbrake(veh, true)

    SetVehicleDoorsLocked(veh, 2)
    SetVehicleDirtLevel(veh, 0.0)
    SetVehicleColours(veh, vehicleColor.primary, vehicleColor.secondary)
    SetVehicleExtraColours(veh, 0, 0)
    spawnedEntity = veh
    return veh
end

local function SpawnStudioObject(modelName, token)
    local hash = GetHashKey(modelName)
    if not LoadModel(hash) then return nil end
    if token and token ~= entitySpawnToken then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end

    local sx, sy, sz = Customize.StudioCoords.x, Customize.StudioCoords.y, Customize.StudioCoords.z
    local playerPos = GetEntityCoords(PlayerPedId())
    local obj = CreateObject(hash, playerPos.x, playerPos.y, playerPos.z, false, false, false)
    if not DoesEntityExist(obj) then return nil end

    SetEntityAsMissionEntity(obj, true, true)
    SetModelAsNoLongerNeeded(hash)
    SetEntityCollision(obj, false, false)
    FreezeEntityPosition(obj, true)

    SetEntityCoordsNoOffset(obj, sx, sy, sz, false, false, false)
    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    SetEntityHeading(obj, Customize.StudioHeading)
    spawnedEntity = obj
    return obj
end

local function DeleteStudioEntity()
    if spawnedEntity then
        local ent = spawnedEntity
        spawnedEntity = nil
        if DoesEntityExist(ent) then
            SetEntityAsMissionEntity(ent, true, true)
            DeleteEntity(ent)
            if DoesEntityExist(ent) then
                SetEntityAsNoLongerNeeded(ent)
                DeleteEntity(ent)
            end
        end
    end
end

local function GetEntityTargetPos()
    if captureMode ~= 'clothing' and spawnedEntity and DoesEntityExist(spawnedEntity) then
        return GetEntityCoords(spawnedEntity)
    end
    return GetEntityCoords(PlayerPedId())
end

local function SnapshotOrbitAngle(cam)
    savedCameraAngles[AngleKey(cam)] = {
        angleH = orbitAngleH,
        dist   = orbitDist,   fov  = orbitFov,
        zPos   = orbitCenter.z - GetEntityTargetPos().z,
        camZ   = orbitCamZ,   roll = orbitRoll,
    }
end

-- ════════════════════════════════════════════════════════
-- ANIMATION HELPERS
-- ════════════════════════════════════════════════════════

local function LoadAnimDict(dict)
    RequestAnimDict(dict)
    local timeout = GetGameTimer() + 5000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < timeout do Wait(10) end
    return HasAnimDictLoaded(dict)
end

local function PlayCategoryAnim(ped, animConfig)
    if not animConfig then return end
    if LoadAnimDict(animConfig.dict) then
        TaskPlayAnim(ped, animConfig.dict, animConfig.name, 8.0, -8.0, -1, animConfig.flag or 49, 0, false, false, false)
        Wait(500)
    end
end

local function StopCategoryAnim(ped)
    ClearPedTasks(ped)
    Wait(100)
end

-- ════════════════════════════════════════════════════════
-- CAPTURE LOOPS
-- ════════════════════════════════════════════════════════

local function SetupCategoryCamera(ped, cameraName)
    local preset   = Customize.CameraPresets[cameraName] or Customize.CameraPresets['tops']
    local hasSaved = GetSavedAngle(cameraName) ~= nil
    DestroyCamera()
    captureCamera = CreateCaptureCamera(ped, preset, cameraName)
    return preset, hasSaved
end

local function ReapplyRotation(ped, preset, hasSaved)
    if hasSaved or preset.defaultAngleH then return end
    SetEntityRotation(ped, preset.rotation.x, preset.rotation.y, preset.rotation.z + captureRotOffset, 2, false)
end

local function CaptureComponents(ped, gender, selectedSet)
    local totalItems, captured = 0, 0
    local allTextures = (activeCaptureOpts and activeCaptureOpts.allTextures ~= nil)
        and activeCaptureOpts.allTextures
        or Customize.CaptureAllTextures
    local rangeMin = activeCaptureOpts and tonumber(activeCaptureOpts.startDrawable)
    local rangeMax = activeCaptureOpts and tonumber(activeCaptureOpts.endDrawable)

    for _, cat in ipairs(Customize.Categories) do
        if not selectedSet or selectedSet[cat.componentId] then
            local n = GetNumberOfPedDrawableVariations(ped, cat.componentId)
            local dStart = rangeMin and math.max(0, rangeMin) or 0
            local dEnd   = rangeMax and math.min(n - 1, rangeMax) or (n - 1)
            if dEnd >= dStart then
                if allTextures then
                    for d = dStart, dEnd do
                        totalItems = totalItems + GetNumberOfPedTextureVariations(ped, cat.componentId, d)
                    end
                else
                    totalItems = totalItems + (dEnd - dStart + 1)
                end
            end
        end
    end

    for _, cat in ipairs(Customize.Categories) do
        if isCancelled then return end
        if selectedSet and not selectedSet[cat.componentId] then goto nextComp end

        local numDrawables = GetNumberOfPedDrawableVariations(ped, cat.componentId)
        local dStart = rangeMin and math.max(0, rangeMin) or 0
        local dEnd   = rangeMax and math.min(numDrawables - 1, rangeMax) or (numDrawables - 1)
        if dEnd < dStart then goto nextComp end

        ResetPedForCategory(ped, cat.visibleComponents, cat.componentOverrides)
        hideHeadActive = cat.hideHead or false
        local preset, hasSaved = SetupCategoryCamera(ped, cat.camera)

        for drawableId = dStart, dEnd do
            if isCancelled then return end
            local maxTex = allTextures and (GetNumberOfPedTextureVariations(ped, cat.componentId, drawableId) - 1) or 0

            for textureId = 0, maxTex do
                if isCancelled then return end
                WaitForResume()
                if isCancelled then return end

                local filename = BuildPhotoKey(gender, 'component', cat.componentId, drawableId, textureId)
                if ShouldSkipKey(filename) then
                    captured = captured + 1
                    SendProgress(captured, totalItems, cat.label, 'components')
                    if captured % 50 == 0 then Wait(0) end
                else
                    WaitForClothingLoaded(ped, cat.componentId, drawableId, textureId)
                    ReapplyRotation(ped, preset, hasSaved)
                    Wait(Customize.WaitAfterApply)

                    CaptureAndUpload(filename)

                    captured = captured + 1
                    SendProgress(captured, totalItems, cat.label, 'components')
                    Wait(Customize.WaitAfterCapture)
                    ThrottledWait()
                end
            end
        end

        ::nextComp::
    end
end

local function CaptureProps(ped, gender, selectedSet)
    local totalItems, captured = 0, 0
    local allTextures = (activeCaptureOpts and activeCaptureOpts.allTextures ~= nil)
        and activeCaptureOpts.allTextures
        or Customize.CaptureAllTextures
    local rangeMin = activeCaptureOpts and tonumber(activeCaptureOpts.startDrawable)
    local rangeMax = activeCaptureOpts and tonumber(activeCaptureOpts.endDrawable)

    for _, cat in ipairs(Customize.PropCategories) do
        if not selectedSet or selectedSet[cat.propId] then
            local n = GetNumberOfPedPropDrawableVariations(ped, cat.propId)
            local dStart = rangeMin and math.max(0, rangeMin) or 0
            local dEnd   = rangeMax and math.min(n - 1, rangeMax) or (n - 1)
            if dEnd >= dStart then
                if allTextures then
                    for d = dStart, dEnd do
                        totalItems = totalItems + GetNumberOfPedPropTextureVariations(ped, cat.propId, d)
                    end
                else
                    totalItems = totalItems + (dEnd - dStart + 1)
                end
            end
        end
    end

    for _, cat in ipairs(Customize.PropCategories) do
        if isCancelled then return end
        if selectedSet and not selectedSet[cat.propId] then goto nextProp end

        local numDrawables = GetNumberOfPedPropDrawableVariations(ped, cat.propId)
        local dStart = rangeMin and math.max(0, rangeMin) or 0
        local dEnd   = rangeMax and math.min(numDrawables - 1, rangeMax) or (numDrawables - 1)
        if dEnd < dStart then goto nextProp end

        ResetPedForCategory(ped, cat.visibleComponents, cat.componentOverrides)
        hideHeadActive = cat.hideHead or false
        local preset, hasSaved = SetupCategoryCamera(ped, cat.camera)
        PlayCategoryAnim(ped, cat.anim)

        for drawableId = dStart, dEnd do
            if isCancelled then return end
            local maxTex = allTextures and (GetNumberOfPedPropTextureVariations(ped, cat.propId, drawableId) - 1) or 0

            for textureId = 0, maxTex do
                if isCancelled then return end
                WaitForResume()
                if isCancelled then return end

                local filename = BuildPhotoKey(gender, 'prop', cat.propId, drawableId, textureId)
                if ShouldSkipKey(filename) then
                    captured = captured + 1
                    SendProgress(captured, totalItems, cat.label, 'props')
                    if captured % 50 == 0 then Wait(0) end
                else
                    WaitForPropLoaded(ped, cat.propId, drawableId, textureId)
                    ReapplyRotation(ped, preset, hasSaved)
                    Wait(Customize.WaitAfterApply)

                    CaptureAndUpload(filename)

                    captured = captured + 1
                    SendProgress(captured, totalItems, cat.label, 'props')
                    Wait(Customize.WaitAfterCapture)
                    ThrottledWait()
                end
            end
        end

        StopCategoryAnim(ped)
        ClearPedProp(ped, cat.propId)
        ::nextProp::
    end
end

local function ApplyOverlayWithColor(ped, overlayIndex, variationId)
    SetPedHeadOverlay(ped, overlayIndex, variationId, 1.0)
    for _, cat in ipairs(Customize.OverlayCategories or {}) do
        if cat.overlayIndex == overlayIndex and cat.colorType then
            SetPedHeadOverlayColor(ped, overlayIndex, cat.colorType, cat.colorId or 1, cat.colorId or 1)
            break
        end
    end
end

-- ════════════════════════════════════════════════════════
-- OVERLAY CAPTURE LOOP
-- ════════════════════════════════════════════════════════

local function CaptureOverlays(ped, gender, selectedSet)
    local cats = Customize.OverlayCategories or {}
    local totalItems, captured = 0, 0
    local rangeMin = activeCaptureOpts and tonumber(activeCaptureOpts.startDrawable)
    local rangeMax = activeCaptureOpts and tonumber(activeCaptureOpts.endDrawable)

    for _, cat in ipairs(cats) do
        if not selectedSet or selectedSet[cat.overlayIndex] then
            local n = GetPedHeadOverlayNum(cat.overlayIndex)
            local dStart = rangeMin and math.max(0, rangeMin) or 0
            local dEnd   = rangeMax and math.min(n - 1, rangeMax) or (n - 1)
            if dEnd >= dStart then
                totalItems = totalItems + (dEnd - dStart + 1)
            end
        end
    end

    for _, cat in ipairs(cats) do
        if isCancelled then return end
        if selectedSet and not selectedSet[cat.overlayIndex] then goto nextOverlay end

        local numVariations = GetPedHeadOverlayNum(cat.overlayIndex)
        local dStart = rangeMin and math.max(0, rangeMin) or 0
        local dEnd   = rangeMax and math.min(numVariations - 1, rangeMax) or (numVariations - 1)
        if dEnd < dStart then goto nextOverlay end

        ResetPedForCategory(ped, cat.visibleComponents, cat.componentOverrides)
        hideHeadActive = false

        for i = 0, 12 do SetPedHeadOverlay(ped, i, 255, 1.0) end

        local preset, hasSaved = SetupCategoryCamera(ped, cat.camera)

        for variationId = dStart, dEnd do
            if isCancelled then return end
            WaitForResume()
            if isCancelled then return end

            local filename = BuildPhotoKey(gender, 'overlay', cat.overlayIndex, variationId, 0)
            if ShouldSkipKey(filename) then
                captured = captured + 1
                SendProgress(captured, totalItems, cat.label, 'overlays')
                if captured % 50 == 0 then Wait(0) end
            else
                ApplyOverlayWithColor(ped, cat.overlayIndex, variationId)
                ReapplyRotation(ped, preset, hasSaved)
                Wait(Customize.WaitAfterApply)

                CaptureAndUpload(filename)

                captured = captured + 1
                SendProgress(captured, totalItems, cat.label, 'overlays')
                Wait(Customize.WaitAfterCapture)
                ThrottledWait()
            end
        end

        ::nextOverlay::
    end
end

-- ════════════════════════════════════════════════════════
-- TATTOOS
-- ════════════════════════════════════════════════════════

local TATTOO_BACK_ANCHORS  = { 'MP_Bea_M_Back_000', 'MP_Buis_M_Back_000' }
local TATTOO_FRONT_ANCHORS = { 'MP_Bea_M_Chest_000', 'MP_Buis_M_Chest_000' }
local TATTOO_VISIBLE       = { 0, 2 }

local tattooList   = nil
local tattooBacks  = nil
local tattooGroups = {}

local function ReadTattooShopItem(faction, index)
    local buf = string.rep('\0', 64)
    Citizen.InvokeNative(0xFF56381874F82086, faction, index, buf)
    local preset = string.unpack('<i4', buf, 25)
    local facing = string.unpack('<i4', buf, 41)
    return preset, facing
end

local function LoadTattooBacks()
    if tattooBacks then return tattooBacks end
    local facings = {}
    for _, faction in ipairs({ 3, 4 }) do
        for i = 0, GetNumTattooShopDlcItems(faction) - 1 do
            local preset, facing = ReadTattooShopItem(faction, i)
            if preset ~= 0 then facings[preset] = facing end
        end
    end

    local function anchorFacing(names)
        for _, name in ipairs(names) do
            local f = facings[GetHashKey(name)]
            if f then return f end
        end
    end
    local backValue, frontValue = anchorFacing(TATTOO_BACK_ANCHORS), anchorFacing(TATTOO_FRONT_ANCHORS)

    tattooBacks = {}
    if backValue and backValue ~= frontValue then
        local backs = 0
        for preset, facing in pairs(facings) do
            if facing == backValue then
                tattooBacks[preset] = true
                backs = backs + 1
            end
        end
        print(('^2[uz_AutoShot]^0 Tattoo shop data: %d back-facing tattoos found'):format(backs))
    else
        print('^3[uz_AutoShot]^0 Tattoo shop data has no usable facing info; torso tattoos all use the front camera. Add back tattoos to Customize.TattooFacing.')
    end
    return tattooBacks
end

local function LoadTattooList()
    if tattooList then return tattooList end
    local source = Customize.Tattoos
    if type(source) ~= 'table' or next(source) == nil then
        source = nil
        if GetResourceState('LNS_Appearance') == 'started' then
            local code = LoadResourceFile('LNS_Appearance', 'shared/tattoos.lua')
            local env = {}
            local chunk = code and load(code, '@LNS_Appearance/shared/tattoos.lua', 't', env)
            if chunk then
                local ok, res = pcall(chunk)
                if ok and type(res) == 'table' then
                    source = res.Tattoos or res
                end
            end
        end
        if (type(source) ~= 'table' or next(source) == nil) and GetResourceState('illenium-appearance') == 'started' then
            local code = LoadResourceFile('illenium-appearance', 'customize/tattoos.lua')
            local env = { Customize = {} }
            local chunk = code and load(code, '@illenium-appearance/customize/tattoos.lua', 't', env)
            if chunk and pcall(chunk) then source = env.Customize.Tattoos end
        end
    end

    local list = {}
    for zone, entries in pairs(type(source) == 'table' and source or {}) do
        for _, t in ipairs(entries) do
            if type(t.collection) == 'string' then
                list[#list + 1] = { zone = t.zone or zone, collection = t.collection, male = t.hashMale, female = t.hashFemale }
            end
        end
    end
    if #list > 0 then tattooList = list end
    return list
end

local function GetTattooGroups(gender)
    if tattooGroups[gender] then return tattooGroups[gender] end
    local cats = Customize.TattooCategories or {}
    local list = LoadTattooList()
    local backs = #list > 0 and LoadTattooBacks() or {}
    local forced = {}
    for name, facing in pairs(Customize.TattooFacing or {}) do forced[name:lower()] = facing end

    local groups = {}
    for i in ipairs(cats) do groups[i] = {} end
    for _, t in ipairs(list) do
        local overlay = gender == 'female' and t.female or t.male
        if type(overlay) == 'string' and overlay ~= '' then
            local facing = forced[overlay:lower()] or (backs[GetHashKey(overlay)] and 'back' or 'front')
            for i, cat in ipairs(cats) do
                if cat.zone == t.zone and (not cat.facing or cat.facing == facing) then
                    groups[i][#groups[i] + 1] = { collection = t.collection, overlay = overlay }
                    break
                end
            end
        end
    end
    if #list > 0 then tattooGroups[gender] = groups end
    return groups
end

local function FindTattooCategoryForOverlay(gender, collection, overlay)
    local groups = GetTattooGroups(gender)
    local targetCol = tostring(collection):lower()
    local targetOv  = tostring(overlay):lower()
    for catIdx, entries in ipairs(groups) do
        for _, t in ipairs(entries) do
            if tostring(t.collection):lower() == targetCol and tostring(t.overlay):lower() == targetOv then
                return catIdx, t
            end
        end
    end
    return nil, nil
end

local function ApplyTattoo(ped, tattoo)
    ClearPedDecorations(ped)
    if tattoo then AddPedDecorationFromHashes(ped, GetHashKey(tattoo.collection), GetHashKey(tattoo.overlay)) end
end

local function CaptureTattoos(ped, gender, selectedSet)
    local cats = Customize.TattooCategories or {}
    local totalItems, captured = 0, 0
    local groups = next(selectedSet) and GetTattooGroups(gender) or {}

    for i in ipairs(cats) do
        if selectedSet[i] and groups[i] then totalItems = totalItems + #groups[i] end
    end

    for i, cat in ipairs(cats) do
        if isCancelled then return end
        if not selectedSet[i] or not groups[i] or #groups[i] == 0 then goto nextTattooCat end

        ResetPedForCategory(ped, TATTOO_VISIBLE, (Customize.TattooBody or {})[gender])
        hideHeadActive = false
        local preset, hasSaved = SetupCategoryCamera(ped, cat.camera)

        for _, tattoo in ipairs(groups[i]) do
            if isCancelled then return end
            WaitForResume()
            if isCancelled then return end

            local filename = TattooFilename(gender, tattoo.collection, tattoo.overlay)
            if ShouldSkipKey(filename) then
                captured = captured + 1
                SendProgress(captured, totalItems, cat.label, 'tattoos')
                if captured % 50 == 0 then Wait(0) end
            else
                ApplyTattoo(ped, tattoo)
                ReapplyRotation(ped, preset, hasSaved)
                Wait(Customize.WaitAfterApply)

                CaptureAndUpload(filename)

                captured = captured + 1
                SendProgress(captured, totalItems, cat.label, 'tattoos')
                Wait(Customize.WaitAfterCapture)
                ThrottledWait()
            end
        end

        ClearPedDecorations(ped)
        ::nextTattooCat::
    end
end

-- ════════════════════════════════════════════════════════
-- VEHICLE CAPTURE LOOP
-- ════════════════════════════════════════════════════════

local function CaptureVehicles(selectedModelSet)
    local totalItems, captured = 0, 0
    local modelsToCapture = {}

    for model in pairs(selectedModelSet) do
        modelsToCapture[#modelsToCapture + 1] = model
        totalItems = totalItems + 1
    end
    table.sort(modelsToCapture)

    for _, model in ipairs(modelsToCapture) do
        if isCancelled then return end
        WaitForResume()
        if isCancelled then return end

        local filename = BuildPhotoKey('male', 'vehicle', model)
        if ShouldSkipKey(filename) then
            captured = captured + 1
            SendProgress(captured, totalItems, model, 'vehicles')
            if captured % 50 == 0 then Wait(0) end
            goto nextVeh
        end

        DeleteStudioEntity()
        local veh = SpawnStudioVehicle(model)
        if not veh then goto nextVeh end

        Wait(500)

        local preset = Customize.CameraPresets['vehicle']
        DestroyCamera()
        captureCamera = CreateCaptureCamera(veh, preset, 'vehicle')
        Wait(Customize.WaitAfterApply)

        if not DoesEntityExist(veh) then
            print(('^3[uz_AutoShot]^0 Vehicle %s was deleted before capture (by another resource?), skipped'):format(model))
            goto nextVeh
        end

        CaptureAndUpload(filename)

        captured = captured + 1
        SendProgress(captured, totalItems, model, 'vehicles')

        DeleteStudioEntity()
        Wait(Customize.WaitAfterCapture)
        ThrottledWait()

        ::nextVeh::
    end
end

-- ════════════════════════════════════════════════════════
-- OBJECT CAPTURE LOOP
-- ════════════════════════════════════════════════════════

local function CaptureObjects(selectedSet)
    local cats = Customize.ObjectCategories or {}
    local totalItems, captured = 0, 0
    local matched = {}

    for _, cat in ipairs(cats) do
        if not selectedSet or selectedSet[cat.model] then
            matched[cat.model] = true
            totalItems = totalItems + 1
        end
    end

    for _, cat in ipairs(cats) do
        if isCancelled then return end
        if selectedSet and not selectedSet[cat.model] then goto nextObj end
        WaitForResume()
        if isCancelled then return end

        local filename = BuildPhotoKey('male', 'object', cat.model)
        if ShouldSkipKey(filename) then
            captured = captured + 1
            SendProgress(captured, totalItems, cat.label, 'objects')
            if captured % 50 == 0 then Wait(0) end
            goto nextObj
        end

        DeleteStudioEntity()
        local obj = SpawnStudioObject(cat.model)
        if not obj then goto nextObj end

        Wait(500)

        local preset = Customize.CameraPresets['object']
        DestroyCamera()
        captureCamera = CreateCaptureCamera(obj, preset, 'object')
        Wait(Customize.WaitAfterApply)

        CaptureAndUpload(filename)

        captured = captured + 1
        SendProgress(captured, totalItems, cat.label, 'objects')

        DeleteStudioEntity()
        Wait(Customize.WaitAfterCapture)
        ThrottledWait()

        ::nextObj::
    end

    -- Also support arbitrary object models passed via headless exports even if unlisted in Customize.ObjectCategories
    if selectedSet then
        for model in pairs(selectedSet) do
            if isCancelled then return end
            if not matched[model] then
                WaitForResume()
                if isCancelled then return end
                local filename = BuildPhotoKey('male', 'object', model)
                if not ShouldSkipKey(filename) then
                    DeleteStudioEntity()
                    local obj = SpawnStudioObject(model)
                    if obj then
                        Wait(500)
                        local preset = Customize.CameraPresets['object']
                        DestroyCamera()
                        captureCamera = CreateCaptureCamera(obj, preset, 'object')
                        Wait(Customize.WaitAfterApply)
                        CaptureAndUpload(filename)
                        DeleteStudioEntity()
                        Wait(Customize.WaitAfterCapture)
                        ThrottledWait()
                    end
                end
                captured = captured + 1
                SendProgress(captured, totalItems, model, 'objects')
            end
        end
    end
end

-- ════════════════════════════════════════════════════════
-- CLEANUP
-- ════════════════════════════════════════════════════════

local function CleanupCapture()
    DestroyCamera()
    DeleteStudioEntity()
    HideHUD(false)
    hideHeadActive    = false
    isCapturing       = false
    isPreview         = false
    isPaused          = false
    isCancelled       = false
    captureMode       = 'clothing'
    activeCaptureOpts = nil
    captureProgress   = nil
    local ped = PlayerPedId()
    if not IsEntityVisible(ped) then SetEntityVisible(ped, true, false) end
    RestoreFullAppearance()
    TriggerServerEvent('uz_autoshot:server:resetBucket')
    SetNuiFocus(false, false)
end

local function FinishCaptureSession(wasCancelled, opts)
    local cb = opts and opts.onComplete
    local hideUi = opts and opts.hideOverlay == true
    local finalMode = captureMode
    CleanupCapture()

    if not hideUi then
        SendNUIMessage({ type = 'forceClose' })
        SendNUIMessage({ type = wasCancelled and 'captureCancelled' or 'captureComplete' })
    end

    if wasCancelled then
        TriggerEvent('uz_autoshot:client:captureCancelled', { mode = finalMode })
    else
        TriggerEvent('uz_autoshot:client:captureComplete', { mode = finalMode })
    end

    if type(cb) == 'function' then
        pcall(cb, not wasCancelled, { cancelled = wasCancelled, mode = finalMode })
    end
end

-- ════════════════════════════════════════════════════════
-- RE-CAPTURE SPECIFIC ITEMS
-- ════════════════════════════════════════════════════════

local function RecaptureSpecificItems(items, opts)
    activeCaptureOpts = opts
    local cameraMap, visibilityMap, animMap, overridesMap, hideHeadMap = {}, {}, {}, {}, {}
    for _, cat in ipairs(Customize.Categories) do
        local key = 'component_' .. cat.componentId
        cameraMap[key]     = cat.camera
        visibilityMap[key] = cat.visibleComponents
        overridesMap[key]  = cat.componentOverrides
        hideHeadMap[key]   = cat.hideHead or false
    end
    for _, cat in ipairs(Customize.PropCategories) do
        local key = 'prop_' .. cat.propId
        cameraMap[key]     = cat.camera
        visibilityMap[key] = cat.visibleComponents
        overridesMap[key]  = cat.componentOverrides
        hideHeadMap[key]   = cat.hideHead or false
        animMap[key]       = cat.anim
    end
    for _, cat in ipairs(Customize.OverlayCategories or {}) do
        local key = 'overlay_' .. cat.overlayIndex
        cameraMap[key]     = cat.camera
        visibilityMap[key] = cat.visibleComponents
        hideHeadMap[key]   = false
    end

    local defaultGender = (opts and (opts.gender == 'male' or opts.gender == 'female') and opts.gender) or captureGender
    captureGender = defaultGender

    HideHUD(true)
    TriggerServerEvent('uz_autoshot:server:setBucket', Customize.RoutingBucket)
    Wait(500)

    local ped = SetupCapturePed(GetHashKey(GENDER_MODELS[captureGender]))
    isCapturing  = true
    isPaused     = false
    isCancelled  = false
    batchCounter = 0

    if not (opts and opts.hideOverlay) then
        SendNUIMessage({ type = 'captureStart' })
    end
    SetNuiFocus(false, false)
    Wait(300)

    local total = #items
    local currentCameraKey = nil
    local currentAnim      = nil
    local captured         = 0

    for _, item in ipairs(items) do
        if isCancelled then break end
        WaitForResume()
        if isCancelled then break end

        local itemGender = (item.gender == 'male' or item.gender == 'female') and item.gender or defaultGender
        if itemGender ~= captureGender then
            if currentAnim then StopCategoryAnim(ped); currentAnim = nil end
            DestroyCamera()
            currentCameraKey = nil
            captureGender = itemGender
            ped = SetupCapturePed(GetHashKey(GENDER_MODELS[captureGender]))
        end

        local tattoo = nil
        local itemKey
        if item.type == 'tattoo' then
            local catIdx = item.id
            if item.collection and item.overlay then
                local foundIdx, foundTattoo = FindTattooCategoryForOverlay(captureGender, item.collection, item.overlay)
                catIdx = catIdx or foundIdx or 1
                tattoo = foundTattoo or { collection = item.collection, overlay = item.overlay }
            else
                tattoo = (GetTattooGroups(captureGender)[catIdx] or {})[(item.drawable or 0) + 1]
            end
            if not tattoo then goto nextRecaptureItem end
            itemKey = 'tattoo_' .. tostring(catIdx)
            local tattooCat = (Customize.TattooCategories or {})[catIdx]
            cameraMap[itemKey]     = (tattooCat and tattooCat.camera) or 'tattoo_torso'
            visibilityMap[itemKey] = TATTOO_VISIBLE
            overridesMap[itemKey]  = (Customize.TattooBody or {})[captureGender]
            hideHeadMap[itemKey]   = false
        else
            itemKey = item.type .. '_' .. tostring(item.id)
        end

        local visParts   = visibilityMap[itemKey]
        local animConfig = animMap[itemKey]

        ResetPedForCategory(ped, visParts, overridesMap[itemKey])
        hideHeadActive = hideHeadMap[itemKey] or false
        ClearPedDecorations(ped)

        local cameraKey = cameraMap[itemKey] or 'tops'
        local preset    = Customize.CameraPresets[cameraKey] or Customize.CameraPresets['tops']
        local hasSaved  = GetSavedAngle(cameraKey) ~= nil

        if cameraKey ~= currentCameraKey then
            if currentAnim then StopCategoryAnim(ped) end
            DestroyCamera()
            captureCamera    = CreateCaptureCamera(ped, preset, cameraKey)
            currentCameraKey = cameraKey
            currentAnim      = nil
        end

        if animConfig and animConfig ~= currentAnim then
            PlayCategoryAnim(ped, animConfig)
            currentAnim = animConfig
        elseif not animConfig and currentAnim then
            StopCategoryAnim(ped)
            currentAnim = nil
        end

        if item.type == 'overlay' then
            local filename = BuildPhotoKey(captureGender, 'overlay', item.id, item.drawable, 0)
            if not ShouldSkipKey(filename) then
                for i = 0, 12 do SetPedHeadOverlay(ped, i, 255, 1.0) end
                ApplyOverlayWithColor(ped, item.id, item.drawable)
                ReapplyRotation(ped, preset, hasSaved)
                Wait(Customize.WaitAfterApply)
                CaptureAndUpload(filename)
                Wait(Customize.WaitAfterCapture)
                ThrottledWait()
            end
        elseif item.type == 'tattoo' then
            local filename = TattooFilename(captureGender, tattoo.collection, tattoo.overlay)
            if not ShouldSkipKey(filename) then
                ApplyTattoo(ped, tattoo)
                ReapplyRotation(ped, preset, hasSaved)
                Wait(Customize.WaitAfterApply)
                CaptureAndUpload(filename)
                Wait(Customize.WaitAfterCapture)
                ThrottledWait()
            end
        else
            local texStart, texEnd
            if item.allTextures or (opts and opts.allTextures and item.texture == nil) then
                local count = item.type == 'component'
                    and GetNumberOfPedTextureVariations(ped, item.id, item.drawable)
                    or  GetNumberOfPedPropTextureVariations(ped, item.id, item.drawable)
                texStart, texEnd = 0, math.max(0, count - 1)
            else
                local tex = tonumber(item.texture) or 0
                texStart, texEnd = tex, tex
            end

            for tex = texStart, texEnd do
                if isCancelled then break end
                WaitForResume()
                if isCancelled then break end

                local filename = BuildPhotoKey(captureGender, item.type, item.id, item.drawable, tex)
                if not ShouldSkipKey(filename) then
                    if item.type == 'component' then
                        WaitForClothingLoaded(ped, item.id, item.drawable, tex)
                    else
                        WaitForPropLoaded(ped, item.id, item.drawable, tex)
                    end
                    ReapplyRotation(ped, preset, hasSaved)
                    Wait(Customize.WaitAfterApply)
                    CaptureAndUpload(filename)
                    Wait(Customize.WaitAfterCapture)
                    ThrottledWait()
                end
            end
        end

        captured = captured + 1
        SendProgress(captured, total, item.type == 'component' and tostring(item.id)
            or item.type == 'tattoo' and tattoo.overlay
            or (item.type .. '_' .. tostring(item.id)), 'recapture')
        ::nextRecaptureItem::
    end

    WaitForPendingUploads(0)
    local wasCancelled = isCancelled
    FinishCaptureSession(wasCancelled, opts)
end

-- ════════════════════════════════════════════════════════
-- CAPTURE PREVIEW + RUN
-- ════════════════════════════════════════════════════════

local function BuildCategoryList(includeDrawables, includeTattoos)
    local categories = {}
    for _, cat in ipairs(Customize.Categories) do
        local entry = { type = 'component', id = cat.componentId, label = cat.label, camera = cat.camera }
        if includeDrawables then entry.drawables = GetNumberOfPedDrawableVariations(PlayerPedId(), cat.componentId) end
        categories[#categories + 1] = entry
    end
    for _, cat in ipairs(Customize.PropCategories) do
        local entry = { type = 'prop', id = cat.propId, label = cat.label, camera = cat.camera }
        if includeDrawables then entry.drawables = GetNumberOfPedPropDrawableVariations(PlayerPedId(), cat.propId) end
        categories[#categories + 1] = entry
    end
    for _, cat in ipairs(Customize.OverlayCategories or {}) do
        local entry = { type = 'overlay', id = cat.overlayIndex, label = cat.label, camera = cat.camera }
        if includeDrawables then entry.drawables = GetPedHeadOverlayNum(cat.overlayIndex) end
        categories[#categories + 1] = entry
    end
    if includeTattoos and #LoadTattooList() > 0 then
        local groups = GetTattooGroups(captureGender)
        for i, cat in ipairs(Customize.TattooCategories or {}) do
            local entry = { type = 'tattoo', id = i, label = cat.label, camera = cat.camera, count = #groups[i] }
            if includeDrawables then
                entry.drawables = #groups[i]
                entry.tattoos   = groups[i]
            end
            categories[#categories + 1] = entry
        end
    end
    local vehCats = GetVehicleCategories()
    local classGroups = {}
    local classOrder = {}
    for _, cat in ipairs(vehCats) do
        local cls = cat.category or 'Other'
        if not classGroups[cls] then
            classGroups[cls] = {}
            classOrder[#classOrder + 1] = cls
        end
        classGroups[cls][#classGroups[cls] + 1] = cat.model
    end
    for _, cls in ipairs(classOrder) do
        categories[#categories + 1] = {
            type = 'vehicle', id = cls, label = cls, camera = 'vehicle',
            drawables = #classGroups[cls], models = classGroups[cls],
        }
    end
    for _, cat in ipairs(Customize.ObjectCategories or {}) do
        categories[#categories + 1] = { type = 'object', id = cat.model, label = cat.label, camera = 'object', drawables = 1 }
    end
    return categories
end

local function EnterCapturePreview()
    if isCapturing or isPreview or isBrowsing then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('Capture already in progress!')
        EndTextCommandThefeedPostTicker(false, false)
        return false
    end
    if not ServerReady() then return false end

    savedCameraAngles   = {}
    activePreviewCamera = nil
    activeCaptureOpts   = nil
    isPreview           = true

    local ped = PlayerPedId()
    captureGender = GetPedGender(ped)
    SaveFullAppearance(ped)

    TriggerServerEvent('uz_autoshot:server:setBucket', Customize.RoutingBucket)
    Wait(500)
    HideHUD(true)

    ped = SetupCapturePed(GetHashKey(GENDER_MODELS[captureGender]))

    local categories = BuildCategoryList(false, true)
    CreateOrbitCamera(ped, categories[1] and categories[1].camera or 'torso')

    SendNUIMessage({ type = 'capturePreview', categories = categories, gender = captureGender })
    SetNuiFocus(true, true)
    return true
end

local function ResetCapturePhase()
    DestroyCamera()
    DeleteStudioEntity()
    hideHeadActive = false
    captureRotOffset = 0.0
    local ped = PlayerPedId()
    if not IsEntityVisible(ped) then SetEntityVisible(ped, true, false) end
    Wait(200)
end

local function SetupEntityCapturePhase(mode)
    ResetCapturePhase()
    captureMode = mode
    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, Customize.StudioCoords.x, Customize.StudioCoords.y, Customize.StudioCoords.z, false, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    Wait(200)
end

local function RunCapture(selectedComponents, selectedProps, selectedVehicles, selectedObjects, selectedOverlays, bothGenders, selectedTattoos, opts)
    activeCaptureOpts = opts
    if activePreviewCamera and not savedCameraAngles[AngleKey(activePreviewCamera)] then
        SnapshotOrbitAngle(activePreviewCamera)
    end
    captureRotOffset = orbitCam and (math.deg(orbitAngleH) - Customize.StudioHeading) or 0.0
    entitySpawnToken = entitySpawnToken + 1
    DestroyOrbitCamera()
    DeleteStudioEntity()

    isPreview    = false
    isCapturing  = true
    isPaused     = false
    isCancelled  = false
    batchCounter = 0

    local compSet, propSet = {}, {}
    for _, id in ipairs(selectedComponents or {}) do compSet[id] = true end
    for _, id in ipairs(selectedProps or {}) do propSet[id] = true end

    local overlaySet, tattooSet = {}, {}
    for _, id in ipairs(selectedOverlays or {}) do overlaySet[id] = true end
    for _, id in ipairs(selectedTattoos or {}) do tattooSet[id] = true end

    local vehSet, objSet = {}, {}
    for _, id in ipairs(selectedVehicles or {}) do vehSet[id] = true end
    for _, id in ipairs(selectedObjects or {}) do objSet[id] = true end

    local hasPed = next(compSet) or next(propSet) or next(overlaySet) or next(tattooSet)
    local hasVeh = next(vehSet)
    local hasObj = next(objSet)

    if not (opts and opts.hideOverlay) then
        SendNUIMessage({ type = 'captureStart' })
    end
    SetNuiFocus(false, false)
    Wait(300)

    -- ── Phase 1: Clothing + Ped Props + Overlays + Tattoos ──
    if hasPed and not isCancelled then
        local genders = { captureGender }
        if bothGenders then genders[2] = OtherGender(captureGender) end

        for _, gender in ipairs(genders) do
            if isCancelled then break end
            if gender ~= captureGender then
                SetupCapturePed(GetHashKey(GENDER_MODELS[gender]))
                captureGender = gender
            end
            captureMode = 'clothing'
            local ped = PlayerPedId()
            if not IsEntityVisible(ped) then SetEntityVisible(ped, true, false) end
            if next(compSet) then CaptureComponents(ped, captureGender, compSet) end
            if not isCancelled and next(propSet) then CaptureProps(ped, captureGender, propSet) end
            if not isCancelled and next(overlaySet) then CaptureOverlays(ped, captureGender, overlaySet) end
            if not isCancelled and next(tattooSet) then CaptureTattoos(ped, captureGender, tattooSet) end
        end
    end

    -- ── Phase 2: Vehicles ──
    if hasVeh and not isCancelled then
        SetupEntityCapturePhase('vehicle')
        CaptureVehicles(vehSet)
    end

    -- ── Phase 3: Objects ──
    if hasObj and not isCancelled then
        SetupEntityCapturePhase('object')
        CaptureObjects(objSet)
    end

    WaitForPendingUploads(0)
    local wasCancelled = isCancelled
    FinishCaptureSession(wasCancelled, opts)
end

local function CancelPreview()
    if not isPreview then return end
    isPreview = false
    DestroyOrbitCamera()
    DeleteStudioEntity()
    captureMode = 'clothing'
    local ped = PlayerPedId()
    if not IsEntityVisible(ped) then SetEntityVisible(ped, true, false) end
    HideHUD(false)
    RestoreFullAppearance()
    TriggerServerEvent('uz_autoshot:server:resetBucket')
    SetNuiFocus(false, false)
end

local function CloseBrowsing()
    isBrowsing = false
    DestroyOrbitCamera()
    DeleteStudioEntity()
    HideHUD(false)
    captureMode = 'clothing'
    local ped = PlayerPedId()
    if not IsEntityVisible(ped) then SetEntityVisible(ped, true, false) end
    RestoreFullAppearance()
    TriggerServerEvent('uz_autoshot:server:resetBucket')
    SetNuiFocus(false, false)
end

-- ════════════════════════════════════════════════════════
-- HEAD HIDE (chroma key mask)
-- ════════════════════════════════════════════════════════

local function DrawHeadChromaMask(ped)
    if not hideHeadActive then return end
    local gs = Customize.GreenScreen
    local chromaPreset = (activeCaptureOpts and activeCaptureOpts.chromaKey) or Customize.ChromaKeyColor
    local r, g, b
    if chromaPreset == 'green' then
        r, g, b = 0, 177, 64
    elseif chromaPreset == 'magenta' then
        r, g, b = 255, 0, 255
    else
        r, g, b = gs.color.r, gs.color.g, gs.color.b
    end
    local hm = Customize.HeadMask or {}

    local headBone = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0) -- SKEL_Head

    local function drawSphere(m)
        DrawMarker(28,
            headBone.x + (m.offsetX or 0.0),
            headBone.y + (m.offsetY or 0.0),
            headBone.z + (m.offsetZ or 0.138),
            0.0, 0.0, 0.0,
            m.rotX or 0.0, m.rotY or 0.0, m.rotZ or 0.0,
            m.sizeX or 0.12, m.sizeY or 0.15, m.sizeZ or 0.31,
            r, g, b, 255,
            false, false, 2, false, nil, nil, false)
    end

    if hm[1] then
        for _, m in ipairs(hm) do drawSphere(m) end
    else
        drawSphere(hm)
    end
end

-- ════════════════════════════════════════════════════════
-- CROSSHAIR & DEBUG OVERLAY (preview only)
-- ════════════════════════════════════════════════════════

local function DrawCrosshair()
    local cx, cy = 0.5, 0.5
    local size = 0.012
    local thick = 0.001
    local a = 120
    DrawRect(cx, cy, size * 2, thick, 255, 255, 255, a)
    DrawRect(cx, cy, thick, size * 2 * (16.0/9.0), 255, 255, 255, a)
    DrawRect(cx, cy, 0.003, 0.003 * (16.0/9.0), 255, 80, 80, 200)
end

local function DrawDebugText(x, y, text)
    SetTextFont(0)
    SetTextScale(0.30, 0.30)
    SetTextColour(255, 255, 255, 230)
    SetTextDropshadow(1, 0, 0, 0, 255)
    SetTextOutline()
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(x, y)
end

local function DrawCameraDebugOverlay()
    if not orbitCam then return end
    local x = 0.01
    local gap = 0.018
    local lineCount = 7
    local startY = 1.0 - 0.02 - (lineCount * gap)

    local refZ
    if captureMode ~= 'clothing' and spawnedEntity and DoesEntityExist(spawnedEntity) then
        refZ = GetEntityCoords(spawnedEntity).z
    else
        refZ = GetEntityCoords(PlayerPedId()).z
    end
    local zPos = orbitCenter.z - refZ

    DrawDebugText(x, startY,             ('Preset: %s'):format(activePreviewCamera or '?'))
    DrawDebugText(x, startY + gap,       ('FOV: %.1f'):format(orbitFov))
    DrawDebugText(x, startY + gap * 2,   ('Dist: %.2f'):format(orbitDist))
    DrawDebugText(x, startY + gap * 3,   ('AngleH: %.1f'):format(math.deg(orbitAngleH)))
    DrawDebugText(x, startY + gap * 4,   ('CamZ: %.2f'):format(orbitCamZ))
    DrawDebugText(x, startY + gap * 5,   ('zPos: %.2f'):format(zPos))
    DrawDebugText(x, startY + gap * 6,   ('Roll: %.1f'):format(orbitRoll))
end

-- ════════════════════════════════════════════════════════
-- BACKGROUND THREAD
-- ════════════════════════════════════════════════════════

CreateThread(function()
    while true do
        local active = isCapturing or isPreview or isBrowsing
        if active then
            local ped = PlayerPedId()
            SuppressWorld()
            ClearPedTasksImmediately(ped)
            local target = (captureMode ~= 'clothing' and spawnedEntity and DoesEntityExist(spawnedEntity))
                and spawnedEntity or ped
            local activeTransp = (activeCaptureOpts and activeCaptureOpts.transparent ~= nil)
                and activeCaptureOpts.transparent
                or Customize.TransparentBg
            if activeTransp then DrawGreenScreenAndLights(target) end
            if captureMode == 'clothing' then DrawHeadChromaMask(ped) end
            if (isPreview or isBrowsing) and not isCapturing then
                DrawCropOverlay()
                DrawCrosshair()
                DrawCameraDebugOverlay()
            end
        end
        Wait(active and 0 or 1000)
    end
end)

-- ════════════════════════════════════════════════════════
-- CLOTHING MENU
-- ════════════════════════════════════════════════════════

local function OpenClothingMenu()
    if isCapturing or isPreview or isBrowsing then return false end
    isBrowsing = true
    activeCaptureOpts = nil

    local ped = PlayerPedId()
    captureGender = GetPedGender(ped)
    SaveFullAppearance(ped)

    TriggerServerEvent('uz_autoshot:server:setBucket', Customize.RoutingBucket)
    Wait(500)
    HideHUD(true)

    ped = SetupCapturePed(pedAppearance.model)

    local categories = BuildCategoryList(true, true)
    CreateOrbitCamera(ped, categories[1] and categories[1].camera or 'torso')
    SetNuiFocus(true, true)

    SendNUIMessage({
        type       = 'openMenu',
        gender     = captureGender,
        categories = categories,
        imgExt     = SavedImageExt(),
    })
    return true
end

-- ════════════════════════════════════════════════════════
-- NUI CALLBACKS
-- ════════════════════════════════════════════════════════

RegisterNUICallback('startCapture', function(data, cb)
    cb('ok')
    if not isPreview then return end
    CreateThread(function()
        RunCapture(
            data.selectedComponents or {},
            data.selectedProps or {},
            data.selectedVehicles or {},
            data.selectedObjects or {},
            data.selectedOverlays or {},
            data.bothGenders == true,
            data.selectedTattoos or {},
            nil
        )
    end)
end)

RegisterNUICallback('setCaptureGender', function(data, cb)
    local model = GENDER_MODELS[data.gender]
    if not isPreview or isCapturing or not model then
        cb({ gender = captureGender })
        return
    end
    if data.gender ~= captureGender then
        local ped = SetupCapturePed(GetHashKey(model))
        captureGender = data.gender
        if captureMode ~= 'clothing' then SetEntityVisible(ped, false, false) end
    end
    local tattooCounts = {}
    for i, group in ipairs(GetTattooGroups(captureGender)) do tattooCounts[i] = #group end
    cb({ gender = captureGender, tattooCounts = tattooCounts })
end)

RegisterNUICallback('cancelPreview', function(_, cb)
    CancelPreview()
    cb('ok')
end)

RegisterNUICallback('pauseCapture', function(_, cb)
    isPaused = true
    cb('ok')
end)

RegisterNUICallback('resumeCapture', function(_, cb)
    isPaused = false
    cb('ok')
end)

RegisterNUICallback('cancelCapture', function(_, cb)
    isCancelled = true
    isPaused = false
    cb('ok')
end)

RegisterNUICallback('closeMenu', function(_, cb)
    CloseBrowsing()
    cb('ok')
end)

RegisterNUICallback('applyClothing', function(data, cb)
    cb('ok')
    local ped = PlayerPedId()
    if data.itemType == 'component' then
        SetPedComponentVariation(ped, data.id, data.drawable, data.texture, 0)
    elseif data.itemType == 'prop' then
        if data.drawable == -1 then ClearPedProp(ped, data.id)
        else SetPedPropIndex(ped, data.id, data.drawable, data.texture, true) end
    elseif data.itemType == 'overlay' then
        for i = 0, 12 do SetPedHeadOverlay(ped, i, 255, 1.0) end
        ApplyOverlayWithColor(ped, data.id, data.drawable)
    elseif data.itemType == 'tattoo' then
        local group = GetTattooGroups(captureGender)[data.id]
        ApplyTattoo(ped, group and group[data.drawable + 1])
    elseif data.itemType == 'vehicle' and data.model then
        entitySpawnToken = entitySpawnToken + 1
        local myToken = entitySpawnToken
        CreateThread(function()
            DeleteStudioEntity()
            Wait(0)
            if entitySpawnToken ~= myToken then return end
            SetEntityVisible(ped, false, false)
            captureMode = 'vehicle'
            SpawnStudioVehicle(data.model, myToken)
            Wait(300)
            if entitySpawnToken ~= myToken then return end
            if spawnedEntity and DoesEntityExist(spawnedEntity) then
                local entityPos = GetEntityCoords(spawnedEntity)
                local preset = Customize.CameraPresets['vehicle']
                if preset then
                    orbitCenter = vector3(entityPos.x, entityPos.y, entityPos.z + preset.zPos)
                    UpdateOrbitCamera()
                end
            end
        end)
    end
end)

RegisterNUICallback('setCameraPreset', function(data, cb)
    local cam = data.camera or 'torso'
    activePreviewCamera = cam

    local isEntityMode = data.categoryType == 'vehicle' or data.categoryType == 'object'

    if not isEntityMode then
        SetOrbitPreset(cam)
    end

    if (isPreview or isBrowsing) and data.categoryType and data.categoryId ~= nil then
        entitySpawnToken = entitySpawnToken + 1

        if isEntityMode then
            local myToken = entitySpawnToken

            CreateThread(function()
                local ped = PlayerPedId()

                DeleteStudioEntity()
                Wait(0)
                if entitySpawnToken ~= myToken then return end

                SetEntityVisible(ped, false, false)
                hideHeadActive = false
                captureMode = data.categoryType

                if data.categoryType == 'vehicle' then
                    local modelToSpawn = data.firstModel
                    if not modelToSpawn then
                        for _, cat in ipairs(GetVehicleCategories()) do
                            if cat.category == data.categoryId then
                                modelToSpawn = cat.model
                                break
                            end
                        end
                    end
                    if modelToSpawn then
                        SpawnStudioVehicle(modelToSpawn, myToken)
                    end
                else
                    SpawnStudioObject(data.categoryId, myToken)
                end

                Wait(300)
                if entitySpawnToken ~= myToken then return end

                if spawnedEntity and DoesEntityExist(spawnedEntity) then
                    local entityPos = GetEntityCoords(spawnedEntity)
                    local preset = Customize.CameraPresets[cam]
                    if preset then
                        orbitCenter   = vector3(entityPos.x, entityPos.y, entityPos.z + preset.zPos)
                        orbitBaseDist = preset.dist or 8.0
                        orbitDist     = orbitBaseDist
                        orbitFov      = preset.fov
                        orbitAngleH   = math.rad(preset.defaultAngleH or 225.0)
                        orbitCamZ     = preset.defaultCamZ or 0.0
                        orbitRoll     = preset.defaultRoll or 0.0
                        if orbitCam then SetCamFov(orbitCam, orbitFov) end
                        UpdateOrbitCamera()
                    end
                end
            end)
        else
            local ped = PlayerPedId()

            if captureMode ~= 'clothing' then
                DeleteStudioEntity()
                SetEntityVisible(ped, true, false)
                captureMode = 'clothing'
            end

            local visComps = {}
            local previewDraw = 0
            local compOverrides = nil
            local shouldHideHead = false

            if data.categoryType == 'component' then
                for _, cat in ipairs(Customize.Categories) do
                    if cat.componentId == data.categoryId then
                        visComps = cat.visibleComponents or {}
                        previewDraw = cat.previewDrawable or 0
                        compOverrides = cat.componentOverrides
                        shouldHideHead = cat.hideHead or false
                        break
                    end
                end
            elseif data.categoryType == 'overlay' then
                for _, cat in ipairs(Customize.OverlayCategories or {}) do
                    if cat.overlayIndex == data.categoryId then
                        visComps = cat.visibleComponents or {}
                        compOverrides = cat.componentOverrides
                        break
                    end
                end
            elseif data.categoryType == 'tattoo' then
                visComps = TATTOO_VISIBLE
                compOverrides = (Customize.TattooBody or {})[captureGender]
            else
                for _, cat in ipairs(Customize.PropCategories) do
                    if cat.propId == data.categoryId then
                        visComps = cat.visibleComponents or {}
                        previewDraw = cat.previewDrawable or 0
                        compOverrides = cat.componentOverrides
                        shouldHideHead = cat.hideHead or false
                        break
                    end
                end
            end

            hideHeadActive = shouldHideHead
            ResetPedForCategory(ped, visComps, compOverrides)
            for i = 0, 12 do SetPedHeadOverlay(ped, i, 255, 1.0) end
            ClearPedDecorations(ped)

            if data.categoryType == 'overlay' then
                ApplyOverlayWithColor(ped, data.categoryId, 0)
            elseif data.categoryType == 'tattoo' then
                local group = GetTattooGroups(captureGender)[data.categoryId]
                ApplyTattoo(ped, group and group[1])
            elseif data.categoryType == 'component' then
                SetPedComponentVariation(ped, data.categoryId, previewDraw, 0, 0)
            else
                SetPedPropIndex(ped, data.categoryId, previewDraw, 0, true)
            end
        end
    end

    local saved = GetSavedAngle(cam)
    if saved then
        orbitAngleH   = saved.angleH
        orbitDist     = saved.dist
        orbitFov      = saved.fov
        orbitCamZ     = saved.camZ or 0.0
        orbitRoll     = saved.roll or 0.0
        if saved.zPos then
            local refZ
            if captureMode ~= 'clothing' and spawnedEntity and DoesEntityExist(spawnedEntity) then
                refZ = GetEntityCoords(spawnedEntity).z
            else
                refZ = GetEntityCoords(PlayerPedId()).z
            end
            orbitCenter = vector3(orbitCenter.x, orbitCenter.y, refZ + saved.zPos)
        end
        if orbitCam then SetCamFov(orbitCam, orbitFov) end
        UpdateOrbitCamera()
    end
    cb('ok')
end)

RegisterNUICallback('saveCameraAngle', function(data, cb)
    local cam = data.camera or activePreviewCamera
    if cam and orbitCam then
        SnapshotOrbitAngle(cam)
        cb({ saved = true, camera = cam })
    else
        cb({ saved = false })
    end
end)

RegisterNUICallback('getCameraValues', function(_, cb)
    if orbitCam then
        local refZ
        if captureMode ~= 'clothing' and spawnedEntity and DoesEntityExist(spawnedEntity) then
            refZ = GetEntityCoords(spawnedEntity).z
        else
            refZ = GetEntityCoords(PlayerPedId()).z
        end
        local vals = {
            preset = activePreviewCamera or '?',
            fov    = tonumber(('%.1f'):format(orbitFov)),
            dist   = tonumber(('%.2f'):format(orbitDist)),
            angleH = tonumber(('%.1f'):format(math.deg(orbitAngleH))),
            camZ   = tonumber(('%.2f'):format(orbitCamZ)),
            zPos   = tonumber(('%.2f'):format(orbitCenter.z - refZ)),
            roll   = tonumber(('%.1f'):format(orbitRoll)),
        }
        local luaStr = ('{ fov = %s, zPos = %s, rotation = vector3(0.0, 0.0, 0.0), dist = %s, defaultAngleH = %s, defaultCamZ = %s, defaultRoll = %s }'):format(
            vals.fov, vals.zPos, vals.dist, vals.angleH, vals.camZ, vals.roll)
        print(('[uz_AutoShot] %s = %s'):format(vals.preset, luaStr))
        vals.luaFormat = luaStr
        cb(vals)
    else
        cb({})
    end
end)

RegisterNUICallback('rotateCamera', function(data, cb)
    if orbitCam then
        orbitAngleH = orbitAngleH - (data.deltaX or 0) * 0.005
        orbitCamZ   = orbitCamZ - (data.deltaY or 0) * 0.003
        UpdateOrbitCamera()
    end
    cb('ok')
end)

RegisterNUICallback('zoomCamera', function(data, cb)
    if orbitCam then
        local maxDist = captureMode == 'vehicle' and 20.0 or captureMode == 'object' and 10.0 or 5.0
        orbitDist = math.max(0.1, math.min(maxDist, orbitDist + (data.delta or 0) * 0.1))
        UpdateOrbitCamera()
    end
    cb('ok')
end)

RegisterNUICallback('rollCamera', function(data, cb)
    if orbitCam then
        orbitRoll = orbitRoll + (data.deltaX or 0) * 0.3
        UpdateOrbitCamera()
    end
    cb('ok')
end)

RegisterNUICallback('adjustZPos', function(data, cb)
    if orbitCam then
        local delta = data.delta or 0
        orbitCenter = vector3(orbitCenter.x, orbitCenter.y, orbitCenter.z + delta)
        UpdateOrbitCamera()
    end
    cb('ok')
end)

RegisterNUICallback('adjustFov', function(data, cb)
    if orbitCam then
        orbitFov = math.max(5.0, math.min(120.0, orbitFov + (data.delta or 0)))
        SetCamFov(orbitCam, orbitFov)
    end
    cb('ok')
end)

RegisterNUICallback('resetCameraPreset', function(_, cb)
    if orbitCam and activePreviewCamera then
        SetOrbitPreset(activePreviewCamera)
    end
    cb('ok')
end)

RegisterNUICallback('setVehicleColor', function(data, cb)
    vehicleColor.primary   = data.primary   or vehicleColor.primary
    vehicleColor.secondary = data.secondary or vehicleColor.secondary
    if spawnedEntity and DoesEntityExist(spawnedEntity) and captureMode == 'vehicle' then
        SetVehicleColours(spawnedEntity, vehicleColor.primary, vehicleColor.secondary)
    end
    cb('ok')
end)

RegisterNUICallback('getTextures', function(data, cb)
    local ped = PlayerPedId()
    local count
    if data.itemType == 'overlay' then
        count = 0
    elseif data.itemType == 'component' then
        count = GetNumberOfPedTextureVariations(ped, data.id, data.drawable)
    else
        count = GetNumberOfPedPropTextureVariations(ped, data.id, data.drawable)
    end
    cb({ count = count })
end)

RegisterNUICallback('enterRecapturePreview', function(_, cb)
    if not ServerReady() then
        CloseBrowsing()
        SendNUIMessage({ type = 'captureCancelled' })
        cb('ok')
        return
    end
    isPreview = true
    HideHUD(true)
    TriggerServerEvent('uz_autoshot:server:setBucket', Customize.RoutingBucket)
    Wait(500)

    local ped = SetupCapturePed(pedAppearance.model or GetEntityModel(PlayerPedId()))

    DestroyOrbitCamera()
    CreateOrbitCamera(ped)
    cb('ok')
end)

RegisterNUICallback('cancelRecapturePreview', function(_, cb)
    isPreview  = false
    isBrowsing = false
    DestroyOrbitCamera()
    HideHUD(false)
    RestoreFullAppearance()
    TriggerServerEvent('uz_autoshot:server:resetBucket')
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('recaptureItems', function(data, cb)
    cb('ok')
    local items = data.items or {}
    if #items == 0 then return end

    captureGender    = GetPedGender(PlayerPedId())
    captureRotOffset = 0.0
    isPreview        = false
    isBrowsing       = false
    activeCaptureOpts = nil

    local cameraMap = {}
    for _, cat in ipairs(Customize.Categories) do cameraMap['component_' .. cat.componentId] = cat.camera end
    for _, cat in ipairs(Customize.PropCategories) do cameraMap['prop_' .. cat.propId] = cat.camera end
    for _, cat in ipairs(Customize.OverlayCategories or {}) do cameraMap['overlay_' .. cat.overlayIndex] = cat.camera end
    for i, cat in ipairs(Customize.TattooCategories or {}) do cameraMap['tattoo_' .. i] = cat.camera end

    savedCameraAngles = {}
    if orbitCam then
        local orbitState = { angleH = orbitAngleH, dist = orbitDist, fov = orbitFov, camZ = orbitCamZ, roll = orbitRoll }
        local seen = {}
        for _, item in ipairs(items) do
            local cam = cameraMap[item.type .. '_' .. item.id]
            if cam and not seen[cam] then
                savedCameraAngles[AngleKey(cam)] = orbitState
                seen[cam] = true
            end
        end
    end

    DestroyOrbitCamera()
    CreateThread(function() RecaptureSpecificItems(items, nil) end)
end)

-- ════════════════════════════════════════════════════════
-- COMMANDS
-- ════════════════════════════════════════════════════════

RegisterCommand(Customize.Command, function() EnterCapturePreview() end, Customize.AceRestricted)
RegisterCommand(Customize.MenuCommand, function() OpenClothingMenu() end, Customize.AceRestricted)

RegisterCommand('shotcar', function(_, args)
    if isCapturing or isPreview or isBrowsing then return end
    if #args == 0 then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('Usage: /shotcar <modelname>')
        EndTextCommandThefeedPostTicker(false, false)
        return
    end

    local modelName = args[1]
    local hash = GetHashKey(modelName)
    if not IsModelAVehicle(hash) then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('Invalid vehicle model: ' .. modelName)
        EndTextCommandThefeedPostTicker(false, false)
        return
    end
    if not ServerReady() then return end

    isPreview = true
    captureMode = 'vehicle'
    activeCaptureOpts = nil
    SaveFullAppearance(PlayerPedId())
    TriggerServerEvent('uz_autoshot:server:setBucket', Customize.RoutingBucket)
    Wait(500)
    HideHUD(true)

    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, Customize.StudioCoords.x, Customize.StudioCoords.y, Customize.StudioCoords.z, false, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)

    SpawnStudioVehicle(modelName)
    Wait(300)

    if spawnedEntity and DoesEntityExist(spawnedEntity) then
        local entityPos = GetEntityCoords(spawnedEntity)
        local preset = Customize.CameraPresets['vehicle']
        orbitCenter = vector3(entityPos.x, entityPos.y, entityPos.z + preset.zPos)
        orbitBaseDist = preset.dist or 8.0
        orbitDist = orbitBaseDist
        orbitFov = preset.fov
        orbitAngleH = math.rad(preset.defaultAngleH or 225.0)
        orbitCamZ = preset.defaultCamZ or 1.5
        orbitRoll = preset.defaultRoll or 0.0

        local camX = orbitCenter.x + orbitDist * math.sin(orbitAngleH)
        local camY = orbitCenter.y - orbitDist * math.cos(orbitAngleH)
        orbitCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', camX, camY, orbitCenter.z, 0.0, 0.0, 0.0, orbitFov, false, 0)
        SetCamActive(orbitCam, true)
        RenderScriptCams(true, false, 0, true, true)
        UpdateOrbitCamera()

        SendNUIMessage({ type = 'singleEntityPreview', model = modelName, entityType = 'vehicle' })
        SetNuiFocus(true, true)
    end
end, Customize.AceRestricted)

RegisterCommand('shotprop', function(_, args)
    if isCapturing or isPreview or isBrowsing then return end
    if #args == 0 then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('Usage: /shotprop <modelname>')
        EndTextCommandThefeedPostTicker(false, false)
        return
    end

    local modelName = args[1]
    local hash = GetHashKey(modelName)
    if not IsModelValid(hash) then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('Invalid object model: ' .. modelName)
        EndTextCommandThefeedPostTicker(false, false)
        return
    end
    if not ServerReady() then return end

    isPreview = true
    captureMode = 'object'
    activeCaptureOpts = nil
    SaveFullAppearance(PlayerPedId())
    TriggerServerEvent('uz_autoshot:server:setBucket', Customize.RoutingBucket)
    Wait(500)
    HideHUD(true)

    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, Customize.StudioCoords.x, Customize.StudioCoords.y, Customize.StudioCoords.z, false, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)

    SpawnStudioObject(modelName)
    Wait(300)

    if spawnedEntity and DoesEntityExist(spawnedEntity) then
        local entityPos = GetEntityCoords(spawnedEntity)
        local preset = Customize.CameraPresets['object']
        orbitCenter = vector3(entityPos.x, entityPos.y, entityPos.z + preset.zPos)
        orbitBaseDist = preset.dist or 3.0
        orbitDist = orbitBaseDist
        orbitFov = preset.fov
        orbitAngleH = math.rad(preset.defaultAngleH or 225.0)
        orbitCamZ = preset.defaultCamZ or 0.5
        orbitRoll = preset.defaultRoll or 0.0

        local camX = orbitCenter.x + orbitDist * math.sin(orbitAngleH)
        local camY = orbitCenter.y - orbitDist * math.cos(orbitAngleH)
        orbitCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', camX, camY, orbitCenter.z, 0.0, 0.0, 0.0, orbitFov, false, 0)
        SetCamActive(orbitCam, true)
        RenderScriptCams(true, false, 0, true, true)
        UpdateOrbitCamera()

        SendNUIMessage({ type = 'singleEntityPreview', model = modelName, entityType = 'object' })
        SetNuiFocus(true, true)
    end
end, Customize.AceRestricted)

RegisterNUICallback('confirmSingleCapture', function(data, cb)
    cb('ok')
    if not isPreview or not spawnedEntity then return end
    local model = data.model or ''
    local eType = data.entityType or 'object'
    local camName = eType == 'vehicle' and 'vehicle' or 'object'

    CreateThread(function()
        SnapshotOrbitAngle(camName)
        captureRotOffset = math.deg(orbitAngleH) - Customize.StudioHeading
        DestroyOrbitCamera()
        isPreview = false
        isCapturing = true
        batchCounter = 0

        SendNUIMessage({ type = 'captureStart' })
        SetNuiFocus(false, false)
        Wait(300)

        local preset = Customize.CameraPresets[camName]
        DestroyCamera()
        captureCamera = CreateCaptureCamera(spawnedEntity, preset, camName)
        Wait(Customize.WaitAfterApply)

        local folder = eType == 'vehicle' and 'vehicles' or 'objects'
        CaptureAndUpload(folder .. '/' .. model)

        SendProgress(1, 1, model, eType)
        WaitForPendingUploads(0)
        FinishCaptureSession(false, activeCaptureOpts)
    end)
end)

RegisterNUICallback('cancelSingleCapture', function(_, cb)
    CancelPreview()
    cb('ok')
end)

-- ════════════════════════════════════════════════════════
-- HEADLESS / PROGRAMMATIC CAPTURE HELPERS
-- ════════════════════════════════════════════════════════

local function ExpandCategorySelection(val, allList, idKey)
    if val == nil then return {} end
    if val == 'all' or val == true then
        local out = {}
        for i, entry in ipairs(allList) do
            out[#out + 1] = idKey and entry[idKey] or i
        end
        return out
    end
    if type(val) == 'table' then return val end
    return { val }
end

local function EnsureMappingsSynced()
    if imageMappingState.synced then return end
    TriggerServerEvent('uz_autoshot:server:requestMappings')
    local timeout = GetGameTimer() + 2500
    while not imageMappingState.synced and GetGameTimer() < timeout do Wait(50) end
end

local function StartHeadlessCapture(options)
    if isCapturing or isPreview or isBrowsing then
        return { started = false, reason = 'AutoShot studio or capture is already active.' }
    end

    local opts = type(options) == 'table' and options or {}

    local comps    = ExpandCategorySelection(opts.components, Customize.Categories or {}, 'componentId')
    local props    = ExpandCategorySelection(opts.props, Customize.PropCategories or {}, 'propId')
    local overlays = ExpandCategorySelection(opts.overlays, Customize.OverlayCategories or {}, 'overlayIndex')
    local tattoos  = ExpandCategorySelection(opts.tattoos, Customize.TattooCategories or {}, nil)

    local vehicles = {}
    if opts.vehicles == 'all' then
        for _, cat in ipairs(GetVehicleCategories()) do vehicles[#vehicles + 1] = cat.model end
    elseif type(opts.vehicles) == 'table' then
        vehicles = opts.vehicles
    elseif type(opts.vehicles) == 'string' and opts.vehicles ~= '' then
        vehicles = { opts.vehicles }
    end

    local objects = {}
    if opts.objects == 'all' then
        for _, cat in ipairs(Customize.ObjectCategories or {}) do objects[#objects + 1] = cat.model end
    elseif type(opts.objects) == 'table' then
        objects = opts.objects
    elseif type(opts.objects) == 'string' and opts.objects ~= '' then
        objects = { opts.objects }
    end

    if #comps == 0 and #props == 0 and #overlays == 0 and #tattoos == 0 and #vehicles == 0 and #objects == 0 then
        return { started = false, reason = 'No categories or items specified for capture.' }
    end

    local ready, reason = ServerReady({
        format = opts.format,
        transparent = opts.transparent,
        silentNotify = true,
    })
    if not ready then
        return { started = false, reason = reason }
    end

    if opts.skipExisting then
        EnsureMappingsSynced()
    end

    savedCameraAngles   = {}
    activePreviewCamera = nil
    captureRotOffset    = 0.0

    local ped = PlayerPedId()
    SaveFullAppearance(ped)

    local bothGenders = opts.bothGenders == true or opts.gender == 'both'
    local initialGender = (opts.gender == 'female' or opts.gender == 'male')
        and opts.gender
        or (bothGenders and 'male' or GetPedGender(ped))
    captureGender = initialGender
    isCapturing   = true
    isPaused      = false
    isCancelled   = false

    local hasPed = (#comps > 0 or #props > 0 or #overlays > 0 or #tattoos > 0)

    CreateThread(function()
        TriggerServerEvent('uz_autoshot:server:setBucket', Customize.RoutingBucket)
        Wait(500)
        HideHUD(true)

        if hasPed then
            SetupCapturePed(GetHashKey(GENDER_MODELS[initialGender]))
        else
            local p = PlayerPedId()
            SetEntityCoordsNoOffset(p, Customize.StudioCoords.x, Customize.StudioCoords.y, Customize.StudioCoords.z, false, false, false)
            FreezeEntityPosition(p, true)
            SetEntityVisible(p, false, false)
        end

        RunCapture(comps, props, vehicles, objects, overlays, bothGenders, tattoos, opts)
    end)

    return { started = true }
end

local function StartHeadlessRecapture(items, options)
    if isCapturing or isPreview or isBrowsing then
        return { started = false, reason = 'AutoShot studio or capture is already active.' }
    end
    if type(items) ~= 'table' or #items == 0 then
        return { started = false, reason = 'No items supplied to recaptureItems.' }
    end

    local opts = type(options) == 'table' and options or {}
    local ready, reason = ServerReady({
        format = opts.format,
        transparent = opts.transparent,
        silentNotify = true,
    })
    if not ready then
        return { started = false, reason = reason }
    end

    if opts.skipExisting then
        EnsureMappingsSynced()
    end

    savedCameraAngles   = {}
    activePreviewCamera = nil
    captureRotOffset    = 0.0

    local ped = PlayerPedId()
    captureGender = (opts.gender == 'male' or opts.gender == 'female') and opts.gender or GetPedGender(ped)
    SaveFullAppearance(ped)
    isCapturing = true
    isPaused    = false
    isCancelled = false

    CreateThread(function()
        RecaptureSpecificItems(items, opts)
    end)

    return { started = true }
end

local function CaptureSingleItem(options)
    if type(options) ~= 'table' then
        return { started = false, reason = 'Expected options table in captureItem.' }
    end

    local itemType = tostring(options.type or 'component'):lower()

    if itemType == 'vehicle' or itemType == 'object' then
        local modelName = options.model or options.id
        if type(modelName) ~= 'string' or modelName == '' then
            return { started = false, reason = 'Missing model name for ' .. itemType .. ' capture.' }
        end
        local hash = GetHashKey(modelName)
        if itemType == 'vehicle' and not IsModelAVehicle(hash) then
            return { started = false, reason = 'Invalid vehicle model: ' .. modelName }
        elseif itemType == 'object' and not IsModelValid(hash) then
            return { started = false, reason = 'Invalid object model: ' .. modelName }
        end
        return StartHeadlessCapture({
            vehicles    = itemType == 'vehicle' and { modelName } or nil,
            objects     = itemType == 'object' and { modelName } or nil,
            pathLayout  = options.pathLayout,
            format      = options.format,
            quality     = options.quality,
            width       = options.width,
            height      = options.height,
            transparent = options.transparent,
            chromaKey   = options.chromaKey,
            hideOverlay = options.hideOverlay,
            onProgress  = options.onProgress,
            onComplete  = options.onComplete,
        })
    end

    local genders
    if options.gender == 'both' or options.bothGenders == true then
        genders = { 'male', 'female' }
    elseif options.gender == 'male' or options.gender == 'female' then
        genders = { options.gender }
    else
        genders = { GetPedGender(PlayerPedId()) }
    end

    local items = {}
    for _, g in ipairs(genders) do
        items[#items + 1] = {
            type        = itemType,
            gender      = g,
            id          = tonumber(options.id) or options.id,
            drawable    = tonumber(options.drawable) or 0,
            texture     = options.texture ~= nil and tonumber(options.texture) or nil,
            allTextures = options.allTextures == true,
            collection  = options.collection,
            overlay     = options.overlay,
        }
    end

    return StartHeadlessRecapture(items, options)
end

-- ════════════════════════════════════════════════════════
-- EXPORTS
-- ════════════════════════════════════════════════════════

-- URL & Mapping Lookups
exports('getPhotoURL', function(gender, itemType, id, drawable, texture, opts)
    return ResolvePhotoURL(gender, itemType, id, drawable, texture, opts, false)
end)

exports('getMappedPhotoURL', function(gender, itemType, id, drawable, texture, opts)
    return ResolvePhotoURL(gender, itemType, id, drawable, texture, opts, true)
end)

exports('resolveKeyURL', function(key, ext)
    return ResolveKeyURL(key, ext)
end)

exports('hasImage', function(genderOrKey, itemType, id, drawable, texture, opts)
    local key
    if itemType == nil and type(genderOrKey) == 'string' then
        key = NormalizeImageKey(genderOrKey)
        if key and imageMappingState.mappings[key] then return true end
        return false
    end
    key = BuildPhotoKey(genderOrKey, itemType, id, drawable, texture, opts and opts.pathLayout)
    if key and imageMappingState.mappings[key] then return true end
    if not (opts and opts.pathLayout) then
        local altLayout = GetPathLayout() == 'lns_appearance' and 'autoshot' or 'lns_appearance'
        local altKey = BuildPhotoKey(genderOrKey, itemType, id, drawable, texture, altLayout)
        if altKey and imageMappingState.mappings[altKey] then return true end
    end
    return false
end)

exports('getShotsBaseURL', function()
    return imageMappingState.baseUrl
end)

exports('getPhotoFormat', function()
    return SavedImageExt()
end)

exports('getPathLayout', function()
    return GetPathLayout()
end)

exports('getImageMappings', function()
    local copy = {}
    for k, v in pairs(imageMappingState.mappings or {}) do copy[k] = v end
    return {
        storageType = imageMappingState.storageType,
        baseUrl     = imageMappingState.baseUrl,
        format      = SavedImageExt(),
        pathLayout  = GetPathLayout(),
        synced      = imageMappingState.synced,
        mappings    = copy,
    }
end)

exports('refreshImageMappings', function()
    imageMappingState.synced = false
    TriggerServerEvent('uz_autoshot:server:requestMappings')
    local timeout = GetGameTimer() + 3000
    while not imageMappingState.synced and GetGameTimer() < timeout do Wait(50) end
    return imageMappingState
end)

exports('getVehiclePhotoURL', function(modelName)
    return ResolveKeyURL('vehicles/' .. tostring(modelName))
end)

exports('getObjectPhotoURL', function(modelName)
    return ResolveKeyURL('objects/' .. tostring(modelName))
end)

exports('getTattooURL', function(gender, collection, overlay)
    return ResolveKeyURL(TattooFilename(gender, collection, overlay))
end)

exports('getComponentCategoryMap', function()
    local copy = {}
    for k, v in pairs(LNS_COMPONENT_FOLDERS) do copy[k] = v end
    return copy
end)

exports('getPropCategoryMap', function()
    local copy = {}
    for k, v in pairs(LNS_PROP_FOLDERS) do copy[k] = v end
    return copy
end)

exports('getCategories', function(includeDrawables, includeTattoos)
    return BuildCategoryList(includeDrawables == true, includeTattoos ~= false)
end)

-- UI & Studio Controls
exports('openCapturePreview', function()
    return EnterCapturePreview()
end)

exports('openStudio', function()
    return EnterCapturePreview()
end)

exports('openWardrobe', function()
    return OpenClothingMenu()
end)

exports('closeStudio', function()
    if isCapturing then
        isCancelled = true
        isPaused = false
        return true
    elseif isPreview then
        SendNUIMessage({ type = 'forceClose' })
        CancelPreview()
        return true
    elseif isBrowsing then
        SendNUIMessage({ type = 'forceClose' })
        CloseBrowsing()
        return true
    end
    return false
end)

exports('pauseCapture', function()
    if not isCapturing then return false end
    isPaused = true
    return true
end)

exports('resumeCapture', function()
    if not isCapturing then return false end
    isPaused = false
    return true
end)

exports('cancelCapture', function()
    if not isCapturing then return false end
    isCancelled = true
    isPaused = false
    return true
end)

exports('isCapturing', function()
    return isCapturing
end)

exports('isStudioOpen', function()
    return isPreview or isBrowsing or isCapturing
end)

exports('getCaptureStatus', function()
    local mappedCount = 0
    for _ in pairs(imageMappingState.mappings or {}) do mappedCount = mappedCount + 1 end
    return {
        isCapturing  = isCapturing,
        isPaused     = isPaused,
        isPreview    = isPreview,
        isBrowsing   = isBrowsing,
        mode         = captureMode,
        gender       = captureGender,
        progress     = captureProgress,
        storageType  = imageMappingState.storageType,
        baseUrl      = imageMappingState.baseUrl,
        format       = SavedImageExt(),
        pathLayout   = GetPathLayout(),
        mappedCount  = mappedCount,
    }
end)

-- Headless Programmatic Capture
exports('startCapture', function(options)
    return StartHeadlessCapture(options)
end)

exports('captureItem', function(options)
    return CaptureSingleItem(options)
end)

exports('recaptureItems', function(items, options)
    return StartHeadlessRecapture(items, options)
end)

-- ════════════════════════════════════════════════════════
-- INPUT THREAD
-- ════════════════════════════════════════════════════════

CreateThread(function()
    while true do
        local pollInput = isBrowsing or isPreview or (isCapturing and not isPaused)
        Wait(pollInput and 0 or 500)

        if isBrowsing then
            DisableControlAction(0, 1, true)
            DisableControlAction(0, 2, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 18, true)
            DisableControlAction(0, 322, true)
            DisableControlAction(0, 200, true)

            if IsDisabledControlJustReleased(0, 322) or IsDisabledControlJustReleased(0, 200) then
                SendNUIMessage({ type = 'forceClose' })
                CloseBrowsing()
            end

        elseif isPreview then
            DisableControlAction(0, 322, true)
            DisableControlAction(0, 200, true)
            if IsDisabledControlJustReleased(0, 322) or IsDisabledControlJustReleased(0, 200) then
                SendNUIMessage({ type = 'forceClose' })
                CancelPreview()
            end

        elseif isCapturing and not isPaused then
            DisableControlAction(0, 22, true)
            DisableControlAction(0, 322, true)
            DisableControlAction(0, 200, true)
            if IsDisabledControlJustReleased(0, 22) then isPaused = true end
            if IsDisabledControlJustReleased(0, 322) or IsDisabledControlJustReleased(0, 200) then
                isCancelled = true
                isPaused = false
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE_NAME then return end
    if isCapturing or isPreview or isBrowsing then
        DestroyCamera()
        DestroyOrbitCamera()
        DeleteStudioEntity()
        HideHUD(false)
        SetNuiFocus(false, false)
        local ped = PlayerPedId()
        if DoesEntityExist(ped) then
            SetEntityVisible(ped, true, false)
            SetEntityCollision(ped, true, true)
            FreezeEntityPosition(ped, false)
            SetPlayerControl(PlayerId(), true, 0)
        end
    end
end)
