-- Bridges Customize fields that server.js needs at runtime.
-- JS reads via GetConvar('uz_autoshot_<key>', '<default>').
SetConvar('uz_autoshot_ace_restricted', Customize.AceRestricted and 'true' or 'false')
SetConvar('uz_autoshot_command',        Customize.Command or 'shotmaker')
SetConvar('uz_autoshot_format',         tostring(Customize.ScreenshotFormat or 'png'))
SetConvar('uz_autoshot_quality',        tostring(Customize.ScreenshotQuality or 0.85))
SetConvar('uz_autoshot_path_layout',    tostring(Customize.PathLayout or 'autoshot'))
SetConvar('uz_autoshot_transparent',    Customize.TransparentBg and 'true' or 'false')
