"""Strict base64 decoding with bounded temporary copies for body-limited uploads."""
import base64
import io

CHUNK_CHARACTERS = 64 * 1024  # Multiple of four; at most 48KiB decoded per chunk.


def decode_base64(value):
    """Match validate=True semantics without a full encoded ASCII byte copy.

    Caller must apply its HTTP body limit before JSON parsing. The one retained
    output buffer is sized from that bounded input, never grown by chunk appends.
    """
    if not isinstance(value, str) or not value.isascii():
        raise ValueError('Invalid base64')
    end = len(value)
    padding = 0
    first = value.find('=')
    if first >= 0:
        count = end - first
        if value.count('=', first) != count or first == 0:
            raise ValueError('Invalid base64 padding')
        remainder = first % 4
        if remainder == 0:
            # Preserve the running Python version's strict surplus-padding rule
            # with a constant-size probe, without copying the padding suffix.
            base64.b64decode('AAAA=', validate=True)
            end = first
        elif remainder in (2, 3) and count == 4 - remainder:
            padding = count
        else:
            raise ValueError('Invalid base64 padding')
    if end % 4:
        raise ValueError('Invalid base64 length')
    expected = end // 4 * 3 - padding
    with io.BytesIO() as output:
        if expected:
            output.seek(expected - 1)
            output.write(b'\0')
            output.seek(0)
        for start in range(0, end, CHUNK_CHARACTERS):
            output.write(base64.b64decode(value[start:min(start + CHUNK_CHARACTERS, end)], validate=True))
        if output.tell() != expected:
            raise ValueError('Incomplete base64 data')
        return output.getvalue()
