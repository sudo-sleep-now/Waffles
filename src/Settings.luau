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
	stringCacheMinLength = 16,

	schemaValidationEnabled = true,
	strictBoundsChecking = true,
	maxDepth = 64,
	maxCollectionCount = 100000,
	maxStringBytes = 8 * 1024 * 1024,
	maxBufferBytes = 16 * 1024 * 1024,
	maxPayloadBytes = 32 * 1024 * 1024,
	maxVarintBytes = 8,

	debugAsserts = false,
})
