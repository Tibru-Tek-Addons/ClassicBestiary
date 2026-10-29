local _, CB = ...

-- English loads first; client-locale files can override individual entries afterward.
CB.L = setmetatable({}, { __index = function(_, key) return key end })
