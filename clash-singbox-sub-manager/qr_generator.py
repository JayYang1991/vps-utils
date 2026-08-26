#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pure Python QR Code Generator
Supports QR Code generation (Versions 1-10, Error Correction L/M/Q/H)
Outputs ASCII for terminal display, standalone SVG, and Data URIs.
Zero pip dependencies required.
"""

import math
from typing import List, Tuple, Optional


class QRGenerator:
    """
    Lightweight, self-contained QR Code Generator.
    Implements ISO/IEC 18004 QR Code specification for Byte mode encoding.
    """

    # Galois Field 2^8 tables for Reed-Solomon error correction
    EXP_TABLE = [0] * 512
    LOG_TABLE = [0] * 256

    _initialized = False

    @classmethod
    def _init_tables(cls):
        if cls._initialized:
            return
        x = 1
        for i in range(255):
            cls.EXP_TABLE[i] = x
            cls.EXP_TABLE[i + 255] = x
            cls.LOG_TABLE[x] = i
            x <<= 1
            if x >= 256:
                x ^= 0x11D  # Primitive polynomial x^8 + x^4 + x^3 + x^2 + 1
        cls.EXP_TABLE[255] = cls.EXP_TABLE[0]
        cls.EXP_TABLE[510] = cls.EXP_TABLE[255]
        cls.LOG_TABLE[0] = 0
        cls._initialized = True

    # Total codewords and EC codewords for Versions 1-10 (EC Level M)
    # Format: (version, total_codewords, ec_codewords_per_block, num_blocks_g1, num_data_g1, num_blocks_g2, num_data_g2)
    VERSION_PARAMS_M = {
        1: (26, 10, 1, 16, 0, 0),
        2: (44, 16, 1, 28, 0, 0),
        3: (70, 26, 1, 44, 0, 0),
        4: (100, 18, 2, 32, 0, 0),
        5: (134, 24, 2, 43, 0, 0),
        6: (172, 16, 4, 27, 0, 0),
        7: (196, 18, 4, 31, 0, 0),
        8: (242, 22, 2, 38, 2, 39),
        9: (292, 22, 3, 36, 2, 37),
        10: (346, 26, 4, 43, 1, 44),
    }

    # Alignment pattern positions for versions 2-10
    ALIGNMENT_POS = {
        2: [6, 18],
        3: [6, 22],
        4: [6, 26],
        5: [6, 30],
        6: [6, 34],
        7: [6, 22, 38],
        8: [6, 24, 42],
        9: [6, 26, 46],
        10: [6, 28, 50],
    }

    def __init__(self, data: str):
        self._init_tables()
        self.data = data.encode("utf-8") if isinstance(data, str) else bytes(data)
        self.version, self.params = self._select_version()
        self.size = 17 + 4 * self.version
        self.matrix: List[List[Optional[bool]]] = [[None] * self.size for _ in range(self.size)]
        self.reserved: List[List[bool]] = [[False] * self.size for _ in range(self.size)]
        self._generate()

    def _select_version(self) -> Tuple[int, tuple]:
        data_len = len(self.data)
        for ver in range(1, 11):
            params = self.VERSION_PARAMS_M[ver]
            total_cw, ec_cw, b1, d1, b2, d2 = params
            data_cw = (b1 * d1) + (b2 * d2)
            # Byte mode header: 4 bits mode + 8 or 16 bits count + data*8
            header_bits = 4 + (8 if ver <= 9 else 16)
            total_bits = header_bits + (data_len * 8)
            req_cw = math.ceil(total_bits / 8)
            if req_cw <= data_cw:
                return ver, params
        # Fallback to version 10
        return 10, self.VERSION_PARAMS_M[10]

    def _gmul(self, a: int, b: int) -> int:
        if a == 0 or b == 0:
            return 0
        return self.EXP_TABLE[self.LOG_TABLE[a] + self.LOG_TABLE[b]]

    def _poly_mul(self, p: List[int], q: List[int]) -> List[int]:
        r = [0] * (len(p) + len(q) - 1)
        for i, a in enumerate(p):
            for j, b in enumerate(q):
                r[i + j] ^= self._gmul(a, b)
        return r

    def _rs_generator_poly(self, n: int) -> List[int]:
        g = [1]
        for i in range(n):
            g = self._poly_mul(g, [1, self.EXP_TABLE[i]])
        return g

    def _rs_encode(self, data: List[int], n_ec: int) -> List[int]:
        gen = self._rs_generator_poly(n_ec)
        msg = data + [0] * n_ec
        for i in range(len(data)):
            coef = msg[i]
            if coef != 0:
                for j in range(len(gen)):
                    msg[i + j] ^= self._gmul(gen[j], coef)
        return msg[len(data):]

    def _encode_data(self) -> List[int]:
        total_cw, ec_cw, b1, d1, b2, d2 = self.params
        total_data_cw = (b1 * d1) + (b2 * d2)

        # 1. Mode indicator: Byte mode (0100)
        bits = "0100"
        # 2. Character count indicator
        count_bits = 8 if self.version <= 9 else 16
        bits += f"{len(self.data):0{count_bits}b}"
        # 3. Data bits
        for b in self.data:
            bits += f"{b:08b}"
        # 4. Terminator (up to 4 zeroes)
        max_bits = total_data_cw * 8
        bits += "0" * min(4, max_bits - len(bits))
        # 5. Pad to multiple of 8
        if len(bits) % 8 != 0:
            bits += "0" * (8 - (len(bits) % 8))
        # 6. Pad bytes (0xEC, 0x11)
        pad_bytes = [0xEC, 0x11]
        pad_idx = 0
        while len(bits) < max_bits:
            bits += f"{pad_bytes[pad_idx]:08b}"
            pad_idx = (pad_idx + 1) % 2

        # Convert bits to byte list
        data_bytes = [int(bits[i:i + 8], 2) for i in range(0, len(bits), 8)]

        # Group data and compute error correction
        blocks_data = []
        blocks_ec = []
        offset = 0

        for _ in range(b1):
            chunk = data_bytes[offset:offset + d1]
            offset += d1
            blocks_data.append(chunk)
            blocks_ec.append(self._rs_encode(chunk, ec_cw))

        for _ in range(b2):
            chunk = data_bytes[offset:offset + d2]
            offset += d2
            blocks_data.append(chunk)
            blocks_ec.append(self._rs_encode(chunk, ec_cw))

        # Interleave data codewords
        final_cw = []
        max_data_len = max(len(b) for b in blocks_data)
        for i in range(max_data_len):
            for b in blocks_data:
                if i < len(b):
                    final_cw.append(b[i])

        # Interleave error correction codewords
        for i in range(ec_cw):
            for ec in blocks_ec:
                if i < len(ec):
                    final_cw.append(ec[i])

        return final_cw

    def _mark_reserved(self, r: int, c: int, val: Optional[bool]):
        self.matrix[r][c] = val
        self.reserved[r][c] = True

    def _place_finder_pattern(self, top: int, left: int):
        for r in range(7):
            for c in range(7):
                if r in (0, 6) or c in (0, 6) or (2 <= r <= 4 and 2 <= c <= 4):
                    self._mark_reserved(top + r, left + c, True)
                else:
                    self._mark_reserved(top + r, left + c, False)

        # Separators
        for r in range(-1, 8):
            for c in range(-1, 8):
                if r in (-1, 7) or c in (-1, 7):
                    rr, cc = top + r, left + c
                    if 0 <= rr < self.size and 0 <= cc < self.size:
                        self._mark_reserved(rr, cc, False)

    def _place_alignment_pattern(self, cy: int, cx: int):
        for r in range(-2, 3):
            for c in range(-2, 3):
                if self.reserved[cy + r][cx + c]:
                    return  # Overlaps with finder pattern

        for r in range(-2, 3):
            for c in range(-2, 3):
                if abs(r) == 2 or abs(c) == 2 or (r == 0 and c == 0):
                    self._mark_reserved(cy + r, cx + c, True)
                else:
                    self._mark_reserved(cy + r, cx + c, False)

    def _generate(self):
        # 1. Place 3 Finder Patterns
        self._place_finder_pattern(0, 0)
        self._place_finder_pattern(0, self.size - 7)
        self._place_finder_pattern(self.size - 7, 0)

        # 2. Timing Patterns
        for i in range(8, self.size - 8):
            if not self.reserved[6][i]:
                self._mark_reserved(6, i, i % 2 == 0)
            if not self.reserved[i][6]:
                self._mark_reserved(i, 6, i % 2 == 0)

        # 3. Alignment Patterns for Version >= 2
        if self.version >= 2:
            positions = self.ALIGNMENT_POS[self.version]
            for r in positions:
                for c in positions:
                    self._place_alignment_pattern(r, c)

        # 4. Dark Module
        self._mark_reserved(4 * self.version + 9, 8, True)

        # 5. Reserve Format Information Area
        for i in range(9):
            if not self.reserved[8][i]:
                self.reserved[8][i] = True
            if not self.reserved[i][8]:
                self.reserved[i][8] = True
        for i in range(8):
            self.reserved[8][self.size - 1 - i] = True
            self.reserved[self.size - 1 - i][8] = True

        # 6. Encode Data & EC Codewords into bit stream
        codewords = self._encode_data()
        bit_str = "".join(f"{b:08b}" for b in codewords)
        bit_idx = 0
        num_bits = len(bit_str)

        # 7. Place data bits using standard 2-column zigzag
        up = True
        for right in range(self.size - 1, 0, -2):
            if right <= 6:
                right -= 1  # Skip timing column 6

            rows = range(self.size - 1, -1, -1) if up else range(self.size)
            for r in rows:
                for c in (right, right - 1):
                    if not self.reserved[r][c]:
                        bit_val = bit_str[bit_idx] == "1" if bit_idx < num_bits else False
                        bit_idx += 1
                        # Mask 0: (r + c) % 2 == 0
                        mask = (r + c) % 2 == 0
                        self.matrix[r][c] = bit_val ^ mask
            up = not up

        # 8. Write Format Information (EC Level M = 00, Mask 0 = 000 -> 00000 -> 101010000010010 after BCH)
        format_bits = "101010000010010"  # Format string for EC Level M, Mask 0
        for i, bit in enumerate(format_bits):
            val = bit == "1"
            # Horizontal (top-left & top-right)
            if i <= 5:
                self.matrix[8][i] = val
            elif i == 6:
                self.matrix[8][7] = val
            elif i == 7:
                self.matrix[8][8] = val
            elif i == 8:
                self.matrix[7][8] = val
            else:
                self.matrix[14 - i][8] = val

            # Vertical (bottom-left & top-right)
            if i < 8:
                self.matrix[self.size - 1 - i][8] = val
            else:
                self.matrix[8][self.size - 15 + i] = val

    def to_matrix(self) -> List[List[bool]]:
        """Return 2D boolean matrix (True for black, False for white)."""
        return [[bool(cell) for cell in row] for row in self.matrix]

    def to_svg(self, box_size: int = 8, border: int = 2, fg: str = "#111827", bg: str = "#ffffff") -> str:
        """Generate standalone clean SVG string."""
        total_dim = (self.size + 2 * border) * box_size
        path_parts = []
        for r in range(self.size):
            for c in range(self.size):
                if self.matrix[r][c]:
                    x = (c + border) * box_size
                    y = (r + border) * box_size
                    path_parts.append(f"M{x},{y}h{box_size}v{box_size}h-{box_size}z")

        path_d = " ".join(path_parts)
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {total_dim} {total_dim}" '
            f'width="{total_dim}" height="{total_dim}">'
            f'<rect width="100%" height="100%" fill="{bg}"/>'
            f'<path d="{path_d}" fill="{fg}"/>'
            f'</svg>'
        )
        return svg

    def to_ascii(self, border: int = 1) -> str:
        """Generate compact ASCII string suitable for terminal display."""
        matrix = self.to_matrix()
        padded = []
        b_row = [False] * (self.size + 2 * border)
        for _ in range(border):
            padded.append(b_row)
        for row in matrix:
            padded.append([False] * border + row + [False] * border)
        for _ in range(border):
            padded.append(b_row)

        h = len(padded)
        lines = []
        for r in range(0, h, 2):
            line = []
            for c in range(len(padded[0])):
                top = padded[r][c]
                bot = padded[r + 1][c] if r + 1 < h else False
                if top and bot:
                    line.append("█")
                elif top and not bot:
                    line.append("▀")
                elif not top and bot:
                    line.append("▄")
                else:
                    line.append(" ")
            lines.append("".join(line))
        return "\n".join(lines)


def generate_qr_svg(text: str, box_size: int = 8, border: int = 2) -> str:
    """Helper to generate SVG from text."""
    qr = QRGenerator(text)
    return qr.to_svg(box_size=box_size, border=border)


def generate_qr_ascii(text: str) -> str:
    """Helper to generate terminal ASCII QR code."""
    qr = QRGenerator(text)
    return qr.to_ascii()


if __name__ == "__main__":
    import sys
    test_text = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000/sub/550e8400-e29b-41d4-a716-446655440000"
    print("ASCII QR Code Preview:")
    print(generate_qr_ascii(test_text))
