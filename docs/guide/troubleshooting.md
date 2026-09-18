# Troubleshooting

## `String-reference configuration does not match the payload`

Make `commonKeys` and `stringCacheMinLength` identical on both peers and apply them before encoding or decoding.

## `Schema does not match the encoded payload`

The receiver used a different field/type definition. Deploy schema changes to both peers together or version your remote message at the application layer.

## `Unexpected end of buffer`

The payload was truncated, was decoded by the wrong entry point, or is not a Waffles buffer. Do not retry decoding it as another type.

## `Unsupported value type: Instance`

Instances are intentionally not serialized. Send stable application IDs or register a converter that resolves only an explicitly safe identifier.

## A schema value fails at a nested path

The message names the exact field or array position. Fix the producing value; do not disable validation unless the producer is already strictly typed and trusted.

## Payload rejected by a configured maximum

Prefer reducing or splitting the message. Raise a limit only after assessing the remote's memory and abuse impact.

## Limitations

- Cyclic graphs and shared table identity are not preserved. Repeated table values decode as independent tables.
- Automatic dictionary keys are limited to booleans, numbers, and strings.
- Roblox `Instance`, functions, threads, and connections are unsupported.
- Converter registration is process-local and intentionally cannot be replaced after registration.
- Empty Luau tables have no intrinsic array/map identity and encode as arrays.
- Automatic format compatibility is tied to `WireVersion`; schema compatibility is additionally tied to the schema fingerprint.
- Waffles provides binary structural safety, not encryption, authentication, authorization, or domain validation.
