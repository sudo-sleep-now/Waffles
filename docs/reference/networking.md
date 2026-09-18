# Networking

```luau
-- Client
RemoteEvent:FireServer(Waffles.SerializeAuto({action = "equip", slot = 3}))

-- Server
RemoteEvent.OnServerEvent:Connect(function(player, payload)
    if typeof(payload) ~= "buffer" then
        return
    end

    local ok, message = pcall(function()
        local data = Waffles.DeserializeAuto(payload)
        -- Authorize and validate gameplay meaning here.
    end)

    if not ok then
        warn("Rejected Waffles payload from", player, message)
    end
end)
```

Default decoding is suitable for parsing client-provided buffers: it checks every read and applies allocation limits. Binary safety is not gameplay trust; the server must still authorize actions and validate domain-specific ranges.

Prefer an explicit schema for high-frequency remotes whose structure is known. It reduces both type-tag bytes and dispatch work.

::: tip Snapshot caches
Repeated encodes have a bounded weak identity cache. After the first encode, unchanged table values can reuse the compact wire shape while returned buffers remain isolated from caller mutation. Decode snapshots use two-hit admission: the first decode records only identity metadata, the second decodes directly again and promotes the current wire/value snapshot, and later unchanged decodes return isolated clones. A promoted exact wire can also serve a fresh buffer after an exact `buffersEqual` check; a unique network buffer remains on the direct path without a wire/value copy. This keeps `decodeSnapshotCacheEnabled` safe to enable by default. Cache hits still validate the complete buffer and active configuration, and both encode and decode snapshots are skipped when custom converters are registered.
:::
