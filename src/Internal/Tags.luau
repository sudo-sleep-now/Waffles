--!strict

-- The Waffles automatic wire tags. Values are permanent once published;
-- payload framing/versioning is enforced by init.luau.
return table.freeze({
	Nil = 0,
	False = 1,
	True = 2,
	Integer = 3,
	Float32 = 4,
	Float64 = 5,
	String = 6,
	StringReference = 7,
	Buffer = 8,
	BufferRle = 9,
	Array = 10,
	Map = 11,
	LayoutDefinition = 12,
	LayoutReference = 13,
	CommonKey = 14,
	-- Compact homogeneous record arrays carry their field plan once, then
	-- encode each column without per-value automatic tags.
	TypedRecordArray = 15,

	Vector2 = 20,
	Vector3 = 21,
	Vector2int16 = 22,
	Vector3int16 = 23,
	CFrame = 24,
	Color3 = 25,
	BrickColor = 26,
	UDim = 27,
	UDim2 = 28,
	Rect = 29,
	Ray = 30,
	NumberRange = 31,
	NumberSequence = 32,
	NumberSequenceKeypoint = 33,
	ColorSequence = 34,
	ColorSequenceKeypoint = 35,
	DateTime = 36,
	Font = 37,
	EnumItem = 38,

	Custom = 60,
})
