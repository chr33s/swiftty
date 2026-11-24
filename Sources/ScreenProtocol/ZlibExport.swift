// The RFC 1950 codec lives in `ZlibCodec` so the terminal engine can
// share it for kitty graphics (`o=z`); RST/1 framing keeps using it here.
@_exported import ZlibCodec
