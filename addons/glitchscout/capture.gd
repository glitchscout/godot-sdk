extends RefCounted
## CAPTURE: screenshots as binary-frame-v1 messages (protocol's binary-frame-v1.md).
##
## Routine frames are kept to 256 KB: the requested encoding, then JPEG at lower qualities, then
## downscales. Lossless baselines are PNG at full resolution and only need to fit the 4 MB frame cap.
## Frames bigger than the WebSocket send buffer go out in chunks, and the ACK follows the last one (see
## GlitchscoutSDK.send_frame).

const FRAME_SCREENSHOT := 1
const ENCODING_PNG := 1
const ENCODING_JPEG := 2
const FLAG_FINAL := 1 << 0
const FLAG_CHUNKED := 1 << 1
const FLAG_DOWNSCALED := 1 << 2
const FLAG_REENCODED := 1 << 3
const FLAG_LOSSLESS := 1 << 4
const HEADER_BYTES := 64
const MAX_FRAME_BYTES := 4194304 ## header plus payload, per assembled frame
const ROUTINE_MAX_BYTES := 262144
const MAX_CHUNK_BYTES := 1048576
const JPEG_QUALITY := 0.9
const CAP_QUALITIES := [0.75, 0.6, 0.45]
const MIN_LONG_EDGE := 64

var sdk: Node


func _init(owner: Node) -> void:
	sdk = owner


func on_capture(msg: Dictionary) -> void:
	var image: Image = sdk.capture_source.call() if sdk.capture_source.is_valid() else viewport_image(sdk)
	if image == null or image.is_empty():
		sdk.reply_error(msg, "capture_unavailable", "there is no rendered frame to capture (a headless run, or no renderer)")
		return
	var r := render(image, msg.payload)
	if r.has("error"):
		sdk.reply_error(msg, r.error, r.message)
		return
	var f := {
		"frame_type": FRAME_SCREENSHOT, "encoding": r.encoding, "flags": r.flags, "tick_frame": sdk.tick,
		"request_id": str(msg.get("id", "")), "width": r.width, "height": r.height,
		"source_width": r.source_width, "source_height": r.source_height,
	}
	var tick: int = sdk.tick
	sdk.send_frame(r.payload, f, func(sent: int) -> void:
		if sent == 0:
			sdk.reply_error(msg, "frame_send_failed", "the frame couldn't be sent (the send buffer stayed full)", true)
		else:
			sdk.reply(msg, "ACK", {"result": {"tick_frame": tick, "frames": sent}}))


## What a viewport last rendered, or null when nothing renders (headless).
static func viewport_image(node: Node) -> Image:
	if DisplayServer.get_name() == "headless" or not node.is_inside_tree():
		return null
	var tex := node.get_viewport().get_texture()
	return tex.get_image() if tex else null


## Whether screenshots can work in this run.
static func available() -> bool:
	return DisplayServer.get_name() != "headless"


## Encodes an image for a CAPTURE request {encoding, max_long_edge?, lossless?}: {payload, encoding, flags,
## width, height, source_width, source_height}, or {error, message}.
static func render(source: Image, req: Dictionary) -> Dictionary:
	var img := source.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGB8 and img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var sw := img.get_width()
	var sh := img.get_height()
	if sw < 1 or sh < 1 or sw > 65535 or sh > 65535:
		return {"error": "capture_unavailable", "message": "the frame is %dx%d" % [sw, sh]}
	var flags := 0
	var max_edge := int(req.get("max_long_edge", 0))
	if max_edge > 0 and maxi(sw, sh) > max_edge:
		_shrink(img, float(max_edge) / maxi(sw, sh))
		flags |= FLAG_DOWNSCALED
	var out := {"source_width": sw, "source_height": sh}
	if req.get("lossless", false):
		var png := img.save_png_to_buffer()
		if HEADER_BYTES + png.size() > MAX_FRAME_BYTES:
			return {"error": "frame_too_large", "message": "the lossless %dx%d frame is %d bytes; the cap is %d" % [img.get_width(), img.get_height(), png.size(), MAX_FRAME_BYTES]}
		return _result(out, img, png, ENCODING_PNG, flags | FLAG_LOSSLESS)
	var encoding := ENCODING_PNG if str(req.get("encoding", "png")) == "png" else ENCODING_JPEG
	var data := img.save_png_to_buffer() if encoding == ENCODING_PNG else img.save_jpg_to_buffer(JPEG_QUALITY)
	if HEADER_BYTES + data.size() <= ROUTINE_MAX_BYTES:
		return _result(out, img, data, encoding, flags)
	for q: float in CAP_QUALITIES:
		data = img.save_jpg_to_buffer(q)
		if HEADER_BYTES + data.size() <= ROUTINE_MAX_BYTES:
			return _result(out, img, data, ENCODING_JPEG, flags | FLAG_REENCODED)
	while maxi(img.get_width(), img.get_height()) > MIN_LONG_EDGE:
		_shrink(img, 0.75)
		data = img.save_jpg_to_buffer(CAP_QUALITIES[-1])
		if HEADER_BYTES + data.size() <= ROUTINE_MAX_BYTES:
			return _result(out, img, data, ENCODING_JPEG, flags | FLAG_REENCODED | FLAG_DOWNSCALED)
	return {"error": "frame_too_large", "message": "the frame doesn't fit %d bytes even as a small JPEG" % ROUTINE_MAX_BYTES}


## One binary-frame-v1 message: the 64-byte header for f {frame_type, encoding, flags, tick_frame,
## request_id, width, height, source_width, source_height, chunk_index?, chunk_count?} and the payload.
static func encode_frame(payload: PackedByteArray, f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(HEADER_BYTES) # zero-filled: reserved0, reserved1
	b.encode_u32(0, 0x46425347) # "GSBF"
	b[4] = 1
	b[5] = int(f.frame_type)
	b[6] = int(f.encoding)
	b[7] = int(f.flags)
	b.encode_u16(8, HEADER_BYTES)
	b.encode_u32(12, payload.size())
	b.encode_u64(16, int(f.tick_frame))
	var id := str(f.request_id).replace("-", "").hex_decode()
	for i in mini(id.size(), 16):
		b[24 + i] = id[i]
	b.encode_u16(40, int(f.width))
	b.encode_u16(42, int(f.height))
	b.encode_u16(44, int(f.source_width))
	b.encode_u16(46, int(f.source_height))
	b.encode_u16(48, int(f.get("chunk_index", 0)))
	b.encode_u16(50, int(f.get("chunk_count", 1)))
	b.encode_u32(52, crc32(payload))
	b.append_array(payload)
	return b


## The payload as chunks of at most max_chunk bytes, each a full frame: `chunked` on all, `final_chunk` on
## the last.
static func split(payload: PackedByteArray, f: Dictionary, max_chunk: int) -> Array[PackedByteArray]:
	var count := maxi(1, ceili(float(payload.size()) / max_chunk))
	var out: Array[PackedByteArray] = []
	for i in count:
		var cf := f.duplicate()
		cf.flags = int(f.flags) | FLAG_CHUNKED | (FLAG_FINAL if i == count - 1 else 0)
		cf.chunk_index = i
		cf.chunk_count = count
		out.append(encode_frame(payload.slice(i * max_chunk, mini((i + 1) * max_chunk, payload.size())), cf))
	return out


## CRC-32 (ISO-HDLC, zlib's crc32). Godot has no CRC-32 call, but a gzip stream ends with the CRC-32 of its
## input, so compressing gets it at native speed.
static func crc32(bytes: PackedByteArray) -> int:
	if bytes.is_empty():
		return 0
	var gz := bytes.compress(FileAccess.COMPRESSION_GZIP)
	return gz.decode_u32(gz.size() - 8)


static func _shrink(img: Image, factor: float) -> void:
	img.resize(maxi(1, roundi(img.get_width() * factor)), maxi(1, roundi(img.get_height() * factor)), Image.INTERPOLATE_BILINEAR)


static func _result(out: Dictionary, img: Image, payload: PackedByteArray, encoding: int, flags: int) -> Dictionary:
	out.payload = payload
	out.encoding = encoding
	out.flags = flags
	out.width = img.get_width()
	out.height = img.get_height()
	return out
