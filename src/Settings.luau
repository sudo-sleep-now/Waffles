--!strict

-- Waffles defaults. A fresh copy is created by init.luau so this table is never
-- mutated by consumers that happen to require Settings directly.
return table.freeze({
	poolingEnabled = true,
	writerPoolMaxPerBucket = 8,
	maxPooledWriterSize = 1024 * 1024,
	readerPoolMax = 16,
	initialWriterSize = 256,

	rleThreshold = 0.15,
	sortedKeysCacheEnabled = true,
	sortedKeysCacheTrustMode = false,
	commonKeys = table.freeze({}),
	-- Short repeated labels are common in record arrays.  The first spelling
	-- costs the same and later occurrences use a two-byte reference, so a
	-- low threshold improves both automatic and schema payloads without
	-- penalizing unique strings.
	stringCacheMinLength = 4,

	schemaValidationEnabled = true,
	strictBoundsChecking = true,
	-- Encoding snapshots are useful for repeated sends of the same mutable
	-- object. Decode snapshots use two-hit admission: the first two reads of a
	-- buffer decode normally, and only repeated identities are promoted to a
	-- clone-isolated snapshot. A promoted exact wire may also serve a fresh
	-- buffer after an exact buffersEqual check; unique network buffers avoid
	-- wire/value copies while stable same-buffer loops still get the fast path.
	encodeSnapshotCacheEnabled = true,
	decodeSnapshotCacheEnabled = true,
	maxDepth = 64,
	maxCollectionCount = 100000,
	maxRecordCells = 8000000,
	maxRecordFields = 1024,
	maxStringBytes = 8 * 1024 * 1024,
	maxBufferBytes = 16 * 1024 * 1024,
	maxPayloadBytes = 32 * 1024 * 1024,
	maxVarintBytes = 8,

	debugAsserts = false,
})
