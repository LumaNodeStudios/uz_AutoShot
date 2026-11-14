-- Server-only image storage and CDN credentials.
-- Keep this file in `server_scripts` only (never `shared_scripts` or `files`)
-- so API keys, tokens, and S3 secrets are never replicated to clients.

SvSettings = {
    ImageStorage = {
        -- Options:
        -- 'local'      (Saves into uz_AutoShot/shots/ and serves via cfx-nui)
        -- 'qbox'       (Qbox CDN - Recommended for live CDN without resource restarts)
        -- 'fivemanage' (Fivemanage API v3 - Recommended)
        -- 'r2'         (Cloudflare R2 S3-compatible bucket - Recommended)
        Type = 'qbox',

        -- WebP encoding quality (1-100) when output format is 'webp'
        -- Also overridable per capture or via Customize.ScreenshotQuality
        WebPQuality = 85,

        -- Persist CDN key -> URL mappings using:
        -- 'auto'  (Uses oxmysql `autoshot_images` table if started, falls back to `shots/mappings.json`)
        -- 'mysql' (Requires oxmysql)
        -- 'json'  (Local `shots/mappings.json` file only)
        MappingStorage = 'auto',

        -- Also keep a local copy in shots/ when uploading to a CDN
        SaveLocalCopy = false,

        -- Qbox CDN Configuration (https://docs.qbox.re/dashboard/cdn)
        Qbox = {
            ApiKey = '20261108_dIYgQyAautybZOzgzjSc6a0' -- API key generated from your Qbox CDN dashboard
        },

        -- Fivemanage Configuration
        Fivemanage = {
            Url = 'https://api.fivemanage.com/api/v3/file',
            Token = '',
            PublicUrl = 'https://r2.fivemanage.com/', -- Your Fivemanage public URL space
            Folder = '' -- Optional base folder prefix on Fivemanage (uses the 'path' API field)
        },

        -- Cloudflare R2 Configuration
        R2 = {
            AccountId = '',
            AccessKeyId = '',
            SecretAccessKey = '',
            Bucket = 'fivem-assets',
            Folder = 'Appearance/Clothing', -- Optional folder prefix inside bucket (e.g. 'v1' or 'Appearance/Clothing')
            PublicUrl = 'https://pub-xxx.r2.dev' -- The public domain to access files
        }
    }
}

exports('GetSvSettings', function()
    return SvSettings
end)

return SvSettings

