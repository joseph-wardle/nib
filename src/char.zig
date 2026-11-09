// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");

/// Word-motion class of a character.
pub const Class = enum { blank, punctuation, keyword };

/// The character at a byte offset: one valid UTF-8 sequence, or a single byte
/// when the bytes there are not one. `code` is null for such a byte.
pub const Character = struct { code: ?u21, len: u3 };

/// Requires `offset < bytes.len`. Overlong forms, surrogates, code points above
/// U+10FFFF and truncated sequences decode as a single invalid byte.
pub fn decode(bytes: []const u8, offset: usize) Character {
    const lead = bytes[offset];
    if (lead < 0x80) return .{ .code = lead, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(lead) catch return .{ .code = null, .len = 1 };
    if (len > bytes.len - offset) return .{ .code = null, .len = 1 };
    const sequence = bytes[offset..][0..len];
    const code = std.unicode.utf8Decode(sequence) catch return .{ .code = null, .len = 1 };
    return .{ .code = code, .len = len };
}

/// The boundary after the character at a boundary `offset`; CRLF is one
/// character. Returns `bytes.len` at the end.
pub fn next(bytes: []const u8, offset: usize) usize {
    if (offset >= bytes.len) return bytes.len;
    const crlf = bytes[offset] == '\r' and offset + 1 < bytes.len and bytes[offset + 1] == '\n';
    if (crlf) return offset + 2;
    return offset + decode(bytes, offset).len;
}

/// The boundary before a boundary `offset`, agreeing with `next`. Returns 0 at
/// the start.
pub fn previous(bytes: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    if (offset >= 2 and bytes[offset - 2] == '\r' and bytes[offset - 1] == '\n') return offset - 2;
    var back: usize = 1;
    while (back <= 4 and back <= offset) : (back += 1) {
        const lead = offset - back;
        if (continuation(bytes[lead])) continue;
        const character = decode(bytes, lead);
        if (back > 1 and character.code != null and character.len == back) return lead;
        break;
    }
    return offset - 1;
}

/// The last boundary at or before any `offset <= bytes.len`: the start of the
/// character containing it, or the CR of a CRLF.
pub fn start(bytes: []const u8, offset: usize) usize {
    if (offset == 0 or offset >= bytes.len) return offset;
    if (bytes[offset - 1] == '\r' and bytes[offset] == '\n') return offset - 1;
    if (!continuation(bytes[offset])) return offset;
    var back: usize = 1;
    while (back <= 3 and back <= offset) : (back += 1) {
        const lead = offset - back;
        if (continuation(bytes[lead])) continue;
        const character = decode(bytes, lead);
        if (character.code != null and lead + character.len > offset) return lead;
        break;
    }
    return offset;
}

/// Display cells for a code point Nib draws as itself, or null for one it
/// draws as a one-cell placeholder: controls (including tab, which callers
/// expand), and anything outside the allowlist below.
pub fn width(code: u21) ?u2 {
    if (code < 0x80) return if (code >= 0x20 and code < 0x7f) 1 else null;
    const range = find(code) orelse return null;
    return range.width;
}

/// Non-ASCII characters outside the allowlist, and invalid bytes, are keyword
/// characters, as in Vim.
pub fn class(code: ?u21) Class {
    const value = code orelse return .keyword;
    if (value < 0x80) {
        if (value == ' ' or value == '\t') return .blank;
        if (std.ascii.isAlphanumeric(@intCast(value)) or value == '_') return .keyword;
        return .punctuation;
    }
    const range = find(value) orelse return .keyword;
    return range.class;
}

/// Editable text: valid UTF-8 whose only controls are tab, LF and CR before
/// LF. DEL and C1 controls (U+0080 to U+009F) are refused.
pub fn editable(bytes: []const u8) bool {
    for (bytes, 0..) |byte, offset| switch (byte) {
        '\t', '\n' => {},
        '\r' => if (offset + 1 == bytes.len or bytes[offset + 1] != '\n') return false,
        0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => return false,
        // C1 controls are exactly C2 80 to C2 9F in valid UTF-8.
        0xc2 => if (offset + 1 < bytes.len and bytes[offset + 1] <= 0x9f) return false,
        else => {},
    };
    return std.unicode.utf8ValidateSlice(bytes);
}

fn continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn find(code: u21) ?Range {
    var low: usize = 0;
    var high: usize = table.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const range = table[middle];
        if (code < range.first) {
            high = middle;
        } else if (code > range.last) {
            low = middle + 1;
        } else return range;
    }
    return null;
}

const Range = struct { first: u21, last: u21, width: u2, class: Class };

// The allowlist: characters whose display width terminals agree on. Generated
// from Unicode 18.0.0 `EastAsianWidth.txt`, `DerivedGeneralCategory.txt` and
// `DerivedAge.txt`, restricted to these blocks: Latin, Greek, Cyrillic,
// phonetic extensions, general and supplemental punctuation, super- and
// subscripts, currency, letterlike, number forms, arrows, mathematical and
// technical symbols, enclosed alphanumerics, box drawing, block elements,
// shapes, miscellaneous symbols, dingbats, CJK (radicals, symbols, kana,
// Bopomofo, Hangul compatibility jamo and syllables, ideographs, compatibility
// forms, half- and fullwidth forms) and emoji pictographs.
// Excluded within them: code points assigned after Unicode 15.0, so older
// terminal tables still know them; marks; controls, format, surrogate,
// private-use and unassigned code points; line and paragraph separators;
// U+3164, U+FFA0 and skin-tone modifiers, which some terminals draw with no
// width; and narrow characters from U+10000 up, so no drawn character needs more
// than three bytes per cell. East Asian Wide and Fullwidth are two cells,
// everything else one, so ambiguous-width characters are taken as narrow.
// Classes: separators are blank, punctuation and symbols are punctuation,
// letters and numbers are keyword.
const table = [_]Range{
    .{ .first = 0x00A0, .last = 0x00A0, .width = 1, .class = .blank },
    .{ .first = 0x00A1, .last = 0x00A9, .width = 1, .class = .punctuation },
    .{ .first = 0x00AA, .last = 0x00AA, .width = 1, .class = .keyword },
    .{ .first = 0x00AB, .last = 0x00AC, .width = 1, .class = .punctuation },
    .{ .first = 0x00AE, .last = 0x00B1, .width = 1, .class = .punctuation },
    .{ .first = 0x00B2, .last = 0x00B3, .width = 1, .class = .keyword },
    .{ .first = 0x00B4, .last = 0x00B4, .width = 1, .class = .punctuation },
    .{ .first = 0x00B5, .last = 0x00B5, .width = 1, .class = .keyword },
    .{ .first = 0x00B6, .last = 0x00B8, .width = 1, .class = .punctuation },
    .{ .first = 0x00B9, .last = 0x00BA, .width = 1, .class = .keyword },
    .{ .first = 0x00BB, .last = 0x00BB, .width = 1, .class = .punctuation },
    .{ .first = 0x00BC, .last = 0x00BE, .width = 1, .class = .keyword },
    .{ .first = 0x00BF, .last = 0x00BF, .width = 1, .class = .punctuation },
    .{ .first = 0x00C0, .last = 0x00D6, .width = 1, .class = .keyword },
    .{ .first = 0x00D7, .last = 0x00D7, .width = 1, .class = .punctuation },
    .{ .first = 0x00D8, .last = 0x00F6, .width = 1, .class = .keyword },
    .{ .first = 0x00F7, .last = 0x00F7, .width = 1, .class = .punctuation },
    .{ .first = 0x00F8, .last = 0x02C1, .width = 1, .class = .keyword },
    .{ .first = 0x02C2, .last = 0x02C5, .width = 1, .class = .punctuation },
    .{ .first = 0x02C6, .last = 0x02D1, .width = 1, .class = .keyword },
    .{ .first = 0x02D2, .last = 0x02DF, .width = 1, .class = .punctuation },
    .{ .first = 0x02E0, .last = 0x02E4, .width = 1, .class = .keyword },
    .{ .first = 0x02E5, .last = 0x02EB, .width = 1, .class = .punctuation },
    .{ .first = 0x02EC, .last = 0x02EC, .width = 1, .class = .keyword },
    .{ .first = 0x02ED, .last = 0x02ED, .width = 1, .class = .punctuation },
    .{ .first = 0x02EE, .last = 0x02EE, .width = 1, .class = .keyword },
    .{ .first = 0x02EF, .last = 0x02FF, .width = 1, .class = .punctuation },
    .{ .first = 0x0370, .last = 0x0374, .width = 1, .class = .keyword },
    .{ .first = 0x0375, .last = 0x0375, .width = 1, .class = .punctuation },
    .{ .first = 0x0376, .last = 0x0377, .width = 1, .class = .keyword },
    .{ .first = 0x037A, .last = 0x037D, .width = 1, .class = .keyword },
    .{ .first = 0x037E, .last = 0x037E, .width = 1, .class = .punctuation },
    .{ .first = 0x037F, .last = 0x037F, .width = 1, .class = .keyword },
    .{ .first = 0x0384, .last = 0x0385, .width = 1, .class = .punctuation },
    .{ .first = 0x0386, .last = 0x0386, .width = 1, .class = .keyword },
    .{ .first = 0x0387, .last = 0x0387, .width = 1, .class = .punctuation },
    .{ .first = 0x0388, .last = 0x038A, .width = 1, .class = .keyword },
    .{ .first = 0x038C, .last = 0x038C, .width = 1, .class = .keyword },
    .{ .first = 0x038E, .last = 0x03A1, .width = 1, .class = .keyword },
    .{ .first = 0x03A3, .last = 0x03F5, .width = 1, .class = .keyword },
    .{ .first = 0x03F6, .last = 0x03F6, .width = 1, .class = .punctuation },
    .{ .first = 0x03F7, .last = 0x03FF, .width = 1, .class = .keyword },
    .{ .first = 0x0400, .last = 0x0481, .width = 1, .class = .keyword },
    .{ .first = 0x0482, .last = 0x0482, .width = 1, .class = .punctuation },
    .{ .first = 0x048A, .last = 0x052F, .width = 1, .class = .keyword },
    .{ .first = 0x1D00, .last = 0x1DBF, .width = 1, .class = .keyword },
    .{ .first = 0x1E00, .last = 0x1F15, .width = 1, .class = .keyword },
    .{ .first = 0x1F18, .last = 0x1F1D, .width = 1, .class = .keyword },
    .{ .first = 0x1F20, .last = 0x1F45, .width = 1, .class = .keyword },
    .{ .first = 0x1F48, .last = 0x1F4D, .width = 1, .class = .keyword },
    .{ .first = 0x1F50, .last = 0x1F57, .width = 1, .class = .keyword },
    .{ .first = 0x1F59, .last = 0x1F59, .width = 1, .class = .keyword },
    .{ .first = 0x1F5B, .last = 0x1F5B, .width = 1, .class = .keyword },
    .{ .first = 0x1F5D, .last = 0x1F5D, .width = 1, .class = .keyword },
    .{ .first = 0x1F5F, .last = 0x1F7D, .width = 1, .class = .keyword },
    .{ .first = 0x1F80, .last = 0x1FB4, .width = 1, .class = .keyword },
    .{ .first = 0x1FB6, .last = 0x1FBC, .width = 1, .class = .keyword },
    .{ .first = 0x1FBD, .last = 0x1FBD, .width = 1, .class = .punctuation },
    .{ .first = 0x1FBE, .last = 0x1FBE, .width = 1, .class = .keyword },
    .{ .first = 0x1FBF, .last = 0x1FC1, .width = 1, .class = .punctuation },
    .{ .first = 0x1FC2, .last = 0x1FC4, .width = 1, .class = .keyword },
    .{ .first = 0x1FC6, .last = 0x1FCC, .width = 1, .class = .keyword },
    .{ .first = 0x1FCD, .last = 0x1FCF, .width = 1, .class = .punctuation },
    .{ .first = 0x1FD0, .last = 0x1FD3, .width = 1, .class = .keyword },
    .{ .first = 0x1FD6, .last = 0x1FDB, .width = 1, .class = .keyword },
    .{ .first = 0x1FDD, .last = 0x1FDF, .width = 1, .class = .punctuation },
    .{ .first = 0x1FE0, .last = 0x1FEC, .width = 1, .class = .keyword },
    .{ .first = 0x1FED, .last = 0x1FEF, .width = 1, .class = .punctuation },
    .{ .first = 0x1FF2, .last = 0x1FF4, .width = 1, .class = .keyword },
    .{ .first = 0x1FF6, .last = 0x1FFC, .width = 1, .class = .keyword },
    .{ .first = 0x1FFD, .last = 0x1FFE, .width = 1, .class = .punctuation },
    .{ .first = 0x2000, .last = 0x200A, .width = 1, .class = .blank },
    .{ .first = 0x2010, .last = 0x2027, .width = 1, .class = .punctuation },
    .{ .first = 0x202F, .last = 0x202F, .width = 1, .class = .blank },
    .{ .first = 0x2030, .last = 0x205E, .width = 1, .class = .punctuation },
    .{ .first = 0x205F, .last = 0x205F, .width = 1, .class = .blank },
    .{ .first = 0x2070, .last = 0x2071, .width = 1, .class = .keyword },
    .{ .first = 0x2074, .last = 0x2079, .width = 1, .class = .keyword },
    .{ .first = 0x207A, .last = 0x207E, .width = 1, .class = .punctuation },
    .{ .first = 0x207F, .last = 0x2089, .width = 1, .class = .keyword },
    .{ .first = 0x208A, .last = 0x208E, .width = 1, .class = .punctuation },
    .{ .first = 0x2090, .last = 0x209C, .width = 1, .class = .keyword },
    .{ .first = 0x20A0, .last = 0x20C0, .width = 1, .class = .punctuation },
    .{ .first = 0x2100, .last = 0x2101, .width = 1, .class = .punctuation },
    .{ .first = 0x2102, .last = 0x2102, .width = 1, .class = .keyword },
    .{ .first = 0x2103, .last = 0x2106, .width = 1, .class = .punctuation },
    .{ .first = 0x2107, .last = 0x2107, .width = 1, .class = .keyword },
    .{ .first = 0x2108, .last = 0x2109, .width = 1, .class = .punctuation },
    .{ .first = 0x210A, .last = 0x2113, .width = 1, .class = .keyword },
    .{ .first = 0x2114, .last = 0x2114, .width = 1, .class = .punctuation },
    .{ .first = 0x2115, .last = 0x2115, .width = 1, .class = .keyword },
    .{ .first = 0x2116, .last = 0x2118, .width = 1, .class = .punctuation },
    .{ .first = 0x2119, .last = 0x211D, .width = 1, .class = .keyword },
    .{ .first = 0x211E, .last = 0x2123, .width = 1, .class = .punctuation },
    .{ .first = 0x2124, .last = 0x2124, .width = 1, .class = .keyword },
    .{ .first = 0x2125, .last = 0x2125, .width = 1, .class = .punctuation },
    .{ .first = 0x2126, .last = 0x2126, .width = 1, .class = .keyword },
    .{ .first = 0x2127, .last = 0x2127, .width = 1, .class = .punctuation },
    .{ .first = 0x2128, .last = 0x2128, .width = 1, .class = .keyword },
    .{ .first = 0x2129, .last = 0x2129, .width = 1, .class = .punctuation },
    .{ .first = 0x212A, .last = 0x212D, .width = 1, .class = .keyword },
    .{ .first = 0x212E, .last = 0x212E, .width = 1, .class = .punctuation },
    .{ .first = 0x212F, .last = 0x2139, .width = 1, .class = .keyword },
    .{ .first = 0x213A, .last = 0x213B, .width = 1, .class = .punctuation },
    .{ .first = 0x213C, .last = 0x213F, .width = 1, .class = .keyword },
    .{ .first = 0x2140, .last = 0x2144, .width = 1, .class = .punctuation },
    .{ .first = 0x2145, .last = 0x2149, .width = 1, .class = .keyword },
    .{ .first = 0x214A, .last = 0x214D, .width = 1, .class = .punctuation },
    .{ .first = 0x214E, .last = 0x214E, .width = 1, .class = .keyword },
    .{ .first = 0x214F, .last = 0x214F, .width = 1, .class = .punctuation },
    .{ .first = 0x2150, .last = 0x2189, .width = 1, .class = .keyword },
    .{ .first = 0x218A, .last = 0x218B, .width = 1, .class = .punctuation },
    .{ .first = 0x2190, .last = 0x2319, .width = 1, .class = .punctuation },
    .{ .first = 0x231A, .last = 0x231B, .width = 2, .class = .punctuation },
    .{ .first = 0x231C, .last = 0x2328, .width = 1, .class = .punctuation },
    .{ .first = 0x2329, .last = 0x232A, .width = 2, .class = .punctuation },
    .{ .first = 0x232B, .last = 0x23E8, .width = 1, .class = .punctuation },
    .{ .first = 0x23E9, .last = 0x23EC, .width = 2, .class = .punctuation },
    .{ .first = 0x23ED, .last = 0x23EF, .width = 1, .class = .punctuation },
    .{ .first = 0x23F0, .last = 0x23F0, .width = 2, .class = .punctuation },
    .{ .first = 0x23F1, .last = 0x23F2, .width = 1, .class = .punctuation },
    .{ .first = 0x23F3, .last = 0x23F3, .width = 2, .class = .punctuation },
    .{ .first = 0x23F4, .last = 0x23FF, .width = 1, .class = .punctuation },
    .{ .first = 0x2400, .last = 0x2426, .width = 1, .class = .punctuation },
    .{ .first = 0x2440, .last = 0x244A, .width = 1, .class = .punctuation },
    .{ .first = 0x2460, .last = 0x249B, .width = 1, .class = .keyword },
    .{ .first = 0x249C, .last = 0x24E9, .width = 1, .class = .punctuation },
    .{ .first = 0x24EA, .last = 0x24FF, .width = 1, .class = .keyword },
    .{ .first = 0x2500, .last = 0x25FC, .width = 1, .class = .punctuation },
    .{ .first = 0x25FD, .last = 0x25FE, .width = 2, .class = .punctuation },
    .{ .first = 0x25FF, .last = 0x2613, .width = 1, .class = .punctuation },
    .{ .first = 0x2614, .last = 0x2615, .width = 2, .class = .punctuation },
    .{ .first = 0x2616, .last = 0x262F, .width = 1, .class = .punctuation },
    .{ .first = 0x2630, .last = 0x2637, .width = 2, .class = .punctuation },
    .{ .first = 0x2638, .last = 0x2647, .width = 1, .class = .punctuation },
    .{ .first = 0x2648, .last = 0x2653, .width = 2, .class = .punctuation },
    .{ .first = 0x2654, .last = 0x267E, .width = 1, .class = .punctuation },
    .{ .first = 0x267F, .last = 0x267F, .width = 2, .class = .punctuation },
    .{ .first = 0x2680, .last = 0x2689, .width = 1, .class = .punctuation },
    .{ .first = 0x268A, .last = 0x268F, .width = 2, .class = .punctuation },
    .{ .first = 0x2690, .last = 0x2692, .width = 1, .class = .punctuation },
    .{ .first = 0x2693, .last = 0x2693, .width = 2, .class = .punctuation },
    .{ .first = 0x2694, .last = 0x26A0, .width = 1, .class = .punctuation },
    .{ .first = 0x26A1, .last = 0x26A1, .width = 2, .class = .punctuation },
    .{ .first = 0x26A2, .last = 0x26A9, .width = 1, .class = .punctuation },
    .{ .first = 0x26AA, .last = 0x26AB, .width = 2, .class = .punctuation },
    .{ .first = 0x26AC, .last = 0x26BC, .width = 1, .class = .punctuation },
    .{ .first = 0x26BD, .last = 0x26BE, .width = 2, .class = .punctuation },
    .{ .first = 0x26BF, .last = 0x26C3, .width = 1, .class = .punctuation },
    .{ .first = 0x26C4, .last = 0x26C5, .width = 2, .class = .punctuation },
    .{ .first = 0x26C6, .last = 0x26CD, .width = 1, .class = .punctuation },
    .{ .first = 0x26CE, .last = 0x26CE, .width = 2, .class = .punctuation },
    .{ .first = 0x26CF, .last = 0x26D3, .width = 1, .class = .punctuation },
    .{ .first = 0x26D4, .last = 0x26D4, .width = 2, .class = .punctuation },
    .{ .first = 0x26D5, .last = 0x26E9, .width = 1, .class = .punctuation },
    .{ .first = 0x26EA, .last = 0x26EA, .width = 2, .class = .punctuation },
    .{ .first = 0x26EB, .last = 0x26F1, .width = 1, .class = .punctuation },
    .{ .first = 0x26F2, .last = 0x26F3, .width = 2, .class = .punctuation },
    .{ .first = 0x26F4, .last = 0x26F4, .width = 1, .class = .punctuation },
    .{ .first = 0x26F5, .last = 0x26F5, .width = 2, .class = .punctuation },
    .{ .first = 0x26F6, .last = 0x26F9, .width = 1, .class = .punctuation },
    .{ .first = 0x26FA, .last = 0x26FA, .width = 2, .class = .punctuation },
    .{ .first = 0x26FB, .last = 0x26FC, .width = 1, .class = .punctuation },
    .{ .first = 0x26FD, .last = 0x26FD, .width = 2, .class = .punctuation },
    .{ .first = 0x26FE, .last = 0x2704, .width = 1, .class = .punctuation },
    .{ .first = 0x2705, .last = 0x2705, .width = 2, .class = .punctuation },
    .{ .first = 0x2706, .last = 0x2709, .width = 1, .class = .punctuation },
    .{ .first = 0x270A, .last = 0x270B, .width = 2, .class = .punctuation },
    .{ .first = 0x270C, .last = 0x2727, .width = 1, .class = .punctuation },
    .{ .first = 0x2728, .last = 0x2728, .width = 2, .class = .punctuation },
    .{ .first = 0x2729, .last = 0x274B, .width = 1, .class = .punctuation },
    .{ .first = 0x274C, .last = 0x274C, .width = 2, .class = .punctuation },
    .{ .first = 0x274D, .last = 0x274D, .width = 1, .class = .punctuation },
    .{ .first = 0x274E, .last = 0x274E, .width = 2, .class = .punctuation },
    .{ .first = 0x274F, .last = 0x2752, .width = 1, .class = .punctuation },
    .{ .first = 0x2753, .last = 0x2755, .width = 2, .class = .punctuation },
    .{ .first = 0x2756, .last = 0x2756, .width = 1, .class = .punctuation },
    .{ .first = 0x2757, .last = 0x2757, .width = 2, .class = .punctuation },
    .{ .first = 0x2758, .last = 0x2775, .width = 1, .class = .punctuation },
    .{ .first = 0x2776, .last = 0x2793, .width = 1, .class = .keyword },
    .{ .first = 0x2794, .last = 0x2794, .width = 1, .class = .punctuation },
    .{ .first = 0x2795, .last = 0x2797, .width = 2, .class = .punctuation },
    .{ .first = 0x2798, .last = 0x27AF, .width = 1, .class = .punctuation },
    .{ .first = 0x27B0, .last = 0x27B0, .width = 2, .class = .punctuation },
    .{ .first = 0x27B1, .last = 0x27BE, .width = 1, .class = .punctuation },
    .{ .first = 0x27BF, .last = 0x27BF, .width = 2, .class = .punctuation },
    .{ .first = 0x27C0, .last = 0x2B1A, .width = 1, .class = .punctuation },
    .{ .first = 0x2B1B, .last = 0x2B1C, .width = 2, .class = .punctuation },
    .{ .first = 0x2B1D, .last = 0x2B4F, .width = 1, .class = .punctuation },
    .{ .first = 0x2B50, .last = 0x2B50, .width = 2, .class = .punctuation },
    .{ .first = 0x2B51, .last = 0x2B54, .width = 1, .class = .punctuation },
    .{ .first = 0x2B55, .last = 0x2B55, .width = 2, .class = .punctuation },
    .{ .first = 0x2B56, .last = 0x2B73, .width = 1, .class = .punctuation },
    .{ .first = 0x2B76, .last = 0x2B95, .width = 1, .class = .punctuation },
    .{ .first = 0x2B97, .last = 0x2BFF, .width = 1, .class = .punctuation },
    .{ .first = 0x2C60, .last = 0x2C7F, .width = 1, .class = .keyword },
    .{ .first = 0x2E00, .last = 0x2E2E, .width = 1, .class = .punctuation },
    .{ .first = 0x2E2F, .last = 0x2E2F, .width = 1, .class = .keyword },
    .{ .first = 0x2E30, .last = 0x2E5D, .width = 1, .class = .punctuation },
    .{ .first = 0x2E80, .last = 0x2E99, .width = 2, .class = .punctuation },
    .{ .first = 0x2E9B, .last = 0x2EF3, .width = 2, .class = .punctuation },
    .{ .first = 0x2F00, .last = 0x2FD5, .width = 2, .class = .punctuation },
    .{ .first = 0x3000, .last = 0x3000, .width = 2, .class = .blank },
    .{ .first = 0x3001, .last = 0x3004, .width = 2, .class = .punctuation },
    .{ .first = 0x3005, .last = 0x3007, .width = 2, .class = .keyword },
    .{ .first = 0x3008, .last = 0x3020, .width = 2, .class = .punctuation },
    .{ .first = 0x3021, .last = 0x3029, .width = 2, .class = .keyword },
    .{ .first = 0x3030, .last = 0x3030, .width = 2, .class = .punctuation },
    .{ .first = 0x3031, .last = 0x3035, .width = 2, .class = .keyword },
    .{ .first = 0x3036, .last = 0x3037, .width = 2, .class = .punctuation },
    .{ .first = 0x3038, .last = 0x303C, .width = 2, .class = .keyword },
    .{ .first = 0x303D, .last = 0x303E, .width = 2, .class = .punctuation },
    .{ .first = 0x303F, .last = 0x303F, .width = 1, .class = .punctuation },
    .{ .first = 0x3041, .last = 0x3096, .width = 2, .class = .keyword },
    .{ .first = 0x309B, .last = 0x309C, .width = 2, .class = .punctuation },
    .{ .first = 0x309D, .last = 0x309F, .width = 2, .class = .keyword },
    .{ .first = 0x30A0, .last = 0x30A0, .width = 2, .class = .punctuation },
    .{ .first = 0x30A1, .last = 0x30FA, .width = 2, .class = .keyword },
    .{ .first = 0x30FB, .last = 0x30FB, .width = 2, .class = .punctuation },
    .{ .first = 0x30FC, .last = 0x30FF, .width = 2, .class = .keyword },
    .{ .first = 0x3105, .last = 0x312F, .width = 2, .class = .keyword },
    .{ .first = 0x3131, .last = 0x3163, .width = 2, .class = .keyword },
    .{ .first = 0x3165, .last = 0x318E, .width = 2, .class = .keyword },
    .{ .first = 0x31F0, .last = 0x31FF, .width = 2, .class = .keyword },
    .{ .first = 0x3200, .last = 0x321E, .width = 2, .class = .punctuation },
    .{ .first = 0x3220, .last = 0x3229, .width = 2, .class = .keyword },
    .{ .first = 0x322A, .last = 0x3247, .width = 2, .class = .punctuation },
    .{ .first = 0x3248, .last = 0x324F, .width = 1, .class = .keyword },
    .{ .first = 0x3250, .last = 0x3250, .width = 2, .class = .punctuation },
    .{ .first = 0x3251, .last = 0x325F, .width = 2, .class = .keyword },
    .{ .first = 0x3260, .last = 0x327F, .width = 2, .class = .punctuation },
    .{ .first = 0x3280, .last = 0x3289, .width = 2, .class = .keyword },
    .{ .first = 0x328A, .last = 0x32B0, .width = 2, .class = .punctuation },
    .{ .first = 0x32B1, .last = 0x32BF, .width = 2, .class = .keyword },
    .{ .first = 0x32C0, .last = 0x33FF, .width = 2, .class = .punctuation },
    .{ .first = 0x3400, .last = 0x4DBF, .width = 2, .class = .keyword },
    .{ .first = 0x4DC0, .last = 0x4DFF, .width = 2, .class = .punctuation },
    .{ .first = 0x4E00, .last = 0x9FFF, .width = 2, .class = .keyword },
    .{ .first = 0xA720, .last = 0xA721, .width = 1, .class = .punctuation },
    .{ .first = 0xA722, .last = 0xA788, .width = 1, .class = .keyword },
    .{ .first = 0xA789, .last = 0xA78A, .width = 1, .class = .punctuation },
    .{ .first = 0xA78B, .last = 0xA7CA, .width = 1, .class = .keyword },
    .{ .first = 0xA7D0, .last = 0xA7D1, .width = 1, .class = .keyword },
    .{ .first = 0xA7D3, .last = 0xA7D3, .width = 1, .class = .keyword },
    .{ .first = 0xA7D5, .last = 0xA7D9, .width = 1, .class = .keyword },
    .{ .first = 0xA7F2, .last = 0xA7FF, .width = 1, .class = .keyword },
    .{ .first = 0xAB30, .last = 0xAB5A, .width = 1, .class = .keyword },
    .{ .first = 0xAB5B, .last = 0xAB5B, .width = 1, .class = .punctuation },
    .{ .first = 0xAB5C, .last = 0xAB69, .width = 1, .class = .keyword },
    .{ .first = 0xAB6A, .last = 0xAB6B, .width = 1, .class = .punctuation },
    .{ .first = 0xAC00, .last = 0xD7A3, .width = 2, .class = .keyword },
    .{ .first = 0xF900, .last = 0xFA6D, .width = 2, .class = .keyword },
    .{ .first = 0xFA70, .last = 0xFAD9, .width = 2, .class = .keyword },
    .{ .first = 0xFE30, .last = 0xFE4F, .width = 2, .class = .punctuation },
    .{ .first = 0xFF01, .last = 0xFF0F, .width = 2, .class = .punctuation },
    .{ .first = 0xFF10, .last = 0xFF19, .width = 2, .class = .keyword },
    .{ .first = 0xFF1A, .last = 0xFF20, .width = 2, .class = .punctuation },
    .{ .first = 0xFF21, .last = 0xFF3A, .width = 2, .class = .keyword },
    .{ .first = 0xFF3B, .last = 0xFF40, .width = 2, .class = .punctuation },
    .{ .first = 0xFF41, .last = 0xFF5A, .width = 2, .class = .keyword },
    .{ .first = 0xFF5B, .last = 0xFF60, .width = 2, .class = .punctuation },
    .{ .first = 0xFF61, .last = 0xFF65, .width = 1, .class = .punctuation },
    .{ .first = 0xFF66, .last = 0xFF9F, .width = 1, .class = .keyword },
    .{ .first = 0xFFA1, .last = 0xFFBE, .width = 1, .class = .keyword },
    .{ .first = 0xFFC2, .last = 0xFFC7, .width = 1, .class = .keyword },
    .{ .first = 0xFFCA, .last = 0xFFCF, .width = 1, .class = .keyword },
    .{ .first = 0xFFD2, .last = 0xFFD7, .width = 1, .class = .keyword },
    .{ .first = 0xFFDA, .last = 0xFFDC, .width = 1, .class = .keyword },
    .{ .first = 0xFFE0, .last = 0xFFE6, .width = 2, .class = .punctuation },
    .{ .first = 0xFFE8, .last = 0xFFEE, .width = 1, .class = .punctuation },
    .{ .first = 0x1F300, .last = 0x1F320, .width = 2, .class = .punctuation },
    .{ .first = 0x1F32D, .last = 0x1F335, .width = 2, .class = .punctuation },
    .{ .first = 0x1F337, .last = 0x1F37C, .width = 2, .class = .punctuation },
    .{ .first = 0x1F37E, .last = 0x1F393, .width = 2, .class = .punctuation },
    .{ .first = 0x1F3A0, .last = 0x1F3CA, .width = 2, .class = .punctuation },
    .{ .first = 0x1F3CF, .last = 0x1F3D3, .width = 2, .class = .punctuation },
    .{ .first = 0x1F3E0, .last = 0x1F3F0, .width = 2, .class = .punctuation },
    .{ .first = 0x1F3F4, .last = 0x1F3F4, .width = 2, .class = .punctuation },
    .{ .first = 0x1F3F8, .last = 0x1F3FA, .width = 2, .class = .punctuation },
    .{ .first = 0x1F400, .last = 0x1F43E, .width = 2, .class = .punctuation },
    .{ .first = 0x1F440, .last = 0x1F440, .width = 2, .class = .punctuation },
    .{ .first = 0x1F442, .last = 0x1F4FC, .width = 2, .class = .punctuation },
    .{ .first = 0x1F4FF, .last = 0x1F53D, .width = 2, .class = .punctuation },
    .{ .first = 0x1F54B, .last = 0x1F54E, .width = 2, .class = .punctuation },
    .{ .first = 0x1F550, .last = 0x1F567, .width = 2, .class = .punctuation },
    .{ .first = 0x1F57A, .last = 0x1F57A, .width = 2, .class = .punctuation },
    .{ .first = 0x1F595, .last = 0x1F596, .width = 2, .class = .punctuation },
    .{ .first = 0x1F5A4, .last = 0x1F5A4, .width = 2, .class = .punctuation },
    .{ .first = 0x1F5FB, .last = 0x1F64F, .width = 2, .class = .punctuation },
    .{ .first = 0x1F680, .last = 0x1F6C5, .width = 2, .class = .punctuation },
    .{ .first = 0x1F6CC, .last = 0x1F6CC, .width = 2, .class = .punctuation },
    .{ .first = 0x1F6D0, .last = 0x1F6D2, .width = 2, .class = .punctuation },
    .{ .first = 0x1F6D5, .last = 0x1F6D7, .width = 2, .class = .punctuation },
    .{ .first = 0x1F6DC, .last = 0x1F6DF, .width = 2, .class = .punctuation },
    .{ .first = 0x1F6EB, .last = 0x1F6EC, .width = 2, .class = .punctuation },
    .{ .first = 0x1F6F4, .last = 0x1F6FC, .width = 2, .class = .punctuation },
    .{ .first = 0x1F90C, .last = 0x1F93A, .width = 2, .class = .punctuation },
    .{ .first = 0x1F93C, .last = 0x1F945, .width = 2, .class = .punctuation },
    .{ .first = 0x1F947, .last = 0x1F9FF, .width = 2, .class = .punctuation },
    .{ .first = 0x1FA70, .last = 0x1FA7C, .width = 2, .class = .punctuation },
    .{ .first = 0x1FA80, .last = 0x1FA88, .width = 2, .class = .punctuation },
    .{ .first = 0x1FA90, .last = 0x1FABD, .width = 2, .class = .punctuation },
    .{ .first = 0x1FABF, .last = 0x1FAC5, .width = 2, .class = .punctuation },
    .{ .first = 0x1FACE, .last = 0x1FADB, .width = 2, .class = .punctuation },
    .{ .first = 0x1FAE0, .last = 0x1FAE8, .width = 2, .class = .punctuation },
    .{ .first = 0x1FAF0, .last = 0x1FAF8, .width = 2, .class = .punctuation },
    .{ .first = 0x20000, .last = 0x2A6DF, .width = 2, .class = .keyword },
    .{ .first = 0x2A700, .last = 0x2B739, .width = 2, .class = .keyword },
    .{ .first = 0x2B740, .last = 0x2B81D, .width = 2, .class = .keyword },
    .{ .first = 0x2B820, .last = 0x2CEA1, .width = 2, .class = .keyword },
    .{ .first = 0x2CEB0, .last = 0x2EBE0, .width = 2, .class = .keyword },
    .{ .first = 0x2F800, .last = 0x2FA1D, .width = 2, .class = .keyword },
    .{ .first = 0x30000, .last = 0x3134A, .width = 2, .class = .keyword },
    .{ .first = 0x31350, .last = 0x323AF, .width = 2, .class = .keyword },
};

const testing = std.testing;

test "decoding takes one valid sequence or one invalid byte" {
    const Case = struct { bytes: []const u8, code: ?u21, len: u3 };
    const cases = [_]Case{
        .{ .bytes = "a", .code = 'a', .len = 1 },
        .{ .bytes = "\xc3\xa9", .code = 0xe9, .len = 2 },
        .{ .bytes = "\xe2\x80\x94", .code = 0x2014, .len = 3 },
        .{ .bytes = "\xf0\x9f\x98\x80", .code = 0x1f600, .len = 4 },
        .{ .bytes = "\x80", .code = null, .len = 1 },
        .{ .bytes = "\xc0\x80", .code = null, .len = 1 },
        .{ .bytes = "\xed\xa0\x80", .code = null, .len = 1 },
        .{ .bytes = "\xf4\x90\x80\x80", .code = null, .len = 1 },
        .{ .bytes = "\xf5\x80\x80\x80", .code = null, .len = 1 },
        .{ .bytes = "\xe2\x80", .code = null, .len = 1 },
    };
    for (cases) |case| {
        const character = decode(case.bytes, 0);
        try testing.expectEqual(case.code, character.code);
        try testing.expectEqual(case.len, character.len);
    }
}

test "stepping forward and back agree at every boundary, including invalid bytes and CRLF" {
    var random_bytes: [512]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x6e6962);
    const alphabet = [_]u8{ 'a', '\r', '\n', 0x80, 0xbf, 0xc3, 0xa9, 0xe2, 0x94, 0xf0, 0x9f, 0xff };
    for (&random_bytes) |*byte| byte.* = alphabet[prng.random().uintLessThan(usize, alphabet.len)];
    const texts = [_][]const u8{
        "",
        "a\r\nb\r\r\n\n",
        "\xc3\xa9\xe2\x80\x94\xf0\x9f\x98\x80\xe6\x9d\x90",
        "\x80\x80\xc3\xe2\x80\xf0\x9f\x98\xc3\xa9\x80\xed\xa0\x80\xc0\x80",
        &random_bytes,
    };
    var boundaries: [513]usize = undefined;
    for (texts) |text| {
        var count: usize = 0;
        var offset: usize = 0;
        while (true) {
            boundaries[count] = offset;
            count += 1;
            if (offset == text.len) break;
            const after = next(text, offset);
            try testing.expect(after > offset);
            offset = after;
        }
        try testing.expectEqual(@as(usize, 0), previous(text, 0));
        for (1..count) |index| {
            try testing.expectEqual(boundaries[index - 1], previous(text, boundaries[index]));
        }
        var index: usize = 0;
        for (0..text.len + 1) |any| {
            while (index + 1 < count and boundaries[index + 1] <= any) index += 1;
            try testing.expectEqual(boundaries[index], start(text, any));
        }
    }
}

test "editable text is valid UTF-8 whose only controls are tab, LF and CRLF" {
    const accepted = [_][]const u8{
        "",
        "a\tb\r\nc\n",
        "\xc2\xa0\xc3\xa9\xe2\x80\x94\xe2\x9c\x85\xe6\x9d\x90",
        "\xf0\x9f\x98\x80",
    };
    for (accepted) |text| {
        try testing.expect(editable(text));
    }
    const refused = [_][]const u8{
        "\xc3",             "a\x00b",   "a\rb",             "a\r",          "\x1b[2J",
        "\x7f",             "\xc2\x85", "\xc2\x9b",         "\xed\xa0\x80", "\xc0\x80",
        "\xf4\x90\x80\x80", "\x80",     "\xe2\x80\x94\xff",
    };
    for (refused) |text| try testing.expect(!editable(text));
}

test "the allowlist is sorted and disjoint, and needs at most three bytes per cell" {
    var previous_last: u21 = 0x9f;
    for (table) |range| {
        try testing.expect(range.first <= range.last);
        try testing.expect(range.first > previous_last);
        if (range.last >= 0x10000) try testing.expectEqual(@as(u2, 2), range.width);
        previous_last = range.last;
    }
    for (0..0x80) |code| {
        const expected: ?u2 = if (code >= 0x20 and code < 0x7f) 1 else null;
        try testing.expectEqual(expected, width(@intCast(code)));
    }
    for (0x80..0xa0) |code| try testing.expectEqual(@as(?u2, null), width(@intCast(code)));
}

test "every non-ASCII character in the owner's projects is drawn at its width" {
    // The distinct characters found on 2026-11-08 in cenote, mint, rgb, bento and javelin.
    const corpus = "§©°±²³µ·¹½×èéï÷ΔΣαγεηθμπσφабвденорстуяᵢ–—’“”…⁰⁴⁵⁶⁻ⁿ₂₃←→↔⇒∈−√∝∞≈≠≡≤≥⏭⏸─│└├▶▸✅✓❌料材ꟻ";
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < corpus.len) : (offset = next(corpus, offset)) {
        const code = decode(corpus, offset).code.?;
        const wide = code == 0x2705 or code == 0x274c or code == 0x6599 or code == 0x6750;
        try testing.expectEqual(@as(?u2, if (wide) 2 else 1), width(code));
        count += 1;
    }
    try testing.expectEqual(@as(usize, 81), count);
}

test "combining, zero-width, bidi and other unlisted code points are placeholders" {
    const placeholders = [_]u21{
        0x00ad,  0x0300,   0x036f, 0x0483, 0x0489, 0x0591, 0x0627,  0x0915,  0x1100,  0x1160,
        0x1dc0,  0x1dff,   0x200b, 0x200c, 0x200d, 0x200e, 0x200f,  0x2028,  0x2029,  0x202a,
        0x202e,  0x2060,   0x2064, 0x20d0, 0x20ff, 0x302a, 0x302f,  0x3099,  0x309a,  0x3164,
        0xd7ff,  0xe000,   0xfe0f, 0xfeff, 0xffa0, 0xfffd, 0x1d400, 0x1f1e6, 0x1f3fb, 0x1f3ff,
        0xe0001, 0x10ffff,
    };
    for (placeholders) |code| {
        try testing.expectEqual(@as(?u2, null), width(code));
    }
}

test "word classes follow Vim's broad split" {
    const Case = struct { code: ?u21, class: Class };
    const cases = [_]Case{
        .{ .code = ' ', .class = .blank },          .{ .code = '\t', .class = .blank },
        .{ .code = 0x00a0, .class = .blank },       .{ .code = 0x3000, .class = .blank },
        .{ .code = 'a', .class = .keyword },        .{ .code = '_', .class = .keyword },
        .{ .code = 0x00e9, .class = .keyword },     .{ .code = 0x03c3, .class = .keyword },
        .{ .code = 0x6750, .class = .keyword },     .{ .code = 0x0300, .class = .keyword },
        .{ .code = null, .class = .keyword },       .{ .code = '.', .class = .punctuation },
        .{ .code = 0x2014, .class = .punctuation }, .{ .code = 0x2192, .class = .punctuation },
        .{ .code = 0x00d7, .class = .punctuation }, .{ .code = 0x00a7, .class = .punctuation },
        .{ .code = 0x2705, .class = .punctuation },
    };
    for (cases) |case| try testing.expectEqual(case.class, class(case.code));
}
