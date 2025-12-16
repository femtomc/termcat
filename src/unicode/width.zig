const std = @import("std");

/// Returns the display width of a Unicode codepoint.
/// - Returns 0 for control characters, combining marks, ZWJ, and variation selectors
/// - Returns 1 for most characters (narrow/half-width)
/// - Returns 2 for wide characters (CJK, emoji, full-width)
///
/// This is a simplified implementation covering common cases.
/// For full Unicode 15.0 compliance, use generated tables from UCD.
/// Note: Complex emoji sequences (ZWJ sequences) are not fully supported;
/// each codepoint is measured individually.
pub fn codePointWidth(cp: u21) u2 {
    // Control characters have zero width
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) {
        return 0;
    }

    // Zero-width characters (ZWJ, ZWNBSP, variation selectors, etc.)
    if (isZeroWidth(cp)) {
        return 0;
    }

    // Combining marks (selected ranges)
    if (isCombiningMark(cp)) {
        return 0;
    }

    // Wide characters
    if (isWide(cp)) {
        return 2;
    }

    return 1;
}

/// Check if codepoint is a zero-width character (not a combining mark)
fn isZeroWidth(cp: u21) bool {
    return cp == 0x200B or // Zero Width Space
        cp == 0x200C or // Zero Width Non-Joiner
        cp == 0x200D or // Zero Width Joiner (ZWJ)
        cp == 0x2060 or // Word Joiner
        cp == 0xFEFF or // Zero Width No-Break Space (BOM)
        (cp >= 0xFE00 and cp <= 0xFE0F) or // Variation Selectors 1-16
        (cp >= 0xE0100 and cp <= 0xE01EF); // Variation Selectors Supplement
}

/// Check if codepoint is a combining mark (zero-width, attaches to previous base char).
/// This is PUBLIC so Buffer.print can distinguish combining marks from control chars.
pub fn isCombiningMark(cp: u21) bool {
    return
    // Combining Diacritical Marks
    (cp >= 0x0300 and cp <= 0x036F) or
        // Combining Diacritical Marks Extended
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        // Combining Diacritical Marks Supplement
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        // Combining Diacritical Marks for Symbols
        (cp >= 0x20D0 and cp <= 0x20FF) or
        // Combining Half Marks
        (cp >= 0xFE20 and cp <= 0xFE2F);
}

/// Check if codepoint is a wide character (width 2)
/// Covers CJK, emoji, and other East Asian Wide/Fullwidth characters
fn isWide(cp: u21) bool {
    return
    // CJK Radicals Supplement
    (cp >= 0x2E80 and cp <= 0x2EFF) or
        // Kangxi Radicals
        (cp >= 0x2F00 and cp <= 0x2FDF) or
        // CJK Symbols and Punctuation
        (cp >= 0x3000 and cp <= 0x303F) or
        // Hiragana
        (cp >= 0x3040 and cp <= 0x309F) or
        // Katakana
        (cp >= 0x30A0 and cp <= 0x30FF) or
        // Bopomofo
        (cp >= 0x3100 and cp <= 0x312F) or
        // Hangul Compatibility Jamo
        (cp >= 0x3130 and cp <= 0x318F) or
        // Kanbun
        (cp >= 0x3190 and cp <= 0x319F) or
        // Bopomofo Extended
        (cp >= 0x31A0 and cp <= 0x31BF) or
        // CJK Strokes
        (cp >= 0x31C0 and cp <= 0x31EF) or
        // Katakana Phonetic Extensions
        (cp >= 0x31F0 and cp <= 0x31FF) or
        // Enclosed CJK Letters and Months
        (cp >= 0x3200 and cp <= 0x32FF) or
        // CJK Compatibility
        (cp >= 0x3300 and cp <= 0x33FF) or
        // CJK Unified Ideographs Extension A
        (cp >= 0x3400 and cp <= 0x4DBF) or
        // CJK Unified Ideographs
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        // Yi Syllables
        (cp >= 0xA000 and cp <= 0xA48F) or
        // Yi Radicals
        (cp >= 0xA490 and cp <= 0xA4CF) or
        // Hangul Syllables
        (cp >= 0xAC00 and cp <= 0xD7AF) or
        // CJK Compatibility Ideographs
        (cp >= 0xF900 and cp <= 0xFAFF) or
        // Fullwidth Forms
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        // CJK Unified Ideographs Extension B-F
        (cp >= 0x20000 and cp <= 0x2FFFF) or
        // CJK Compatibility Ideographs Supplement
        (cp >= 0x2F800 and cp <= 0x2FA1F) or
        // Emoji (common ranges - simplified)
        (cp >= 0x1F300 and cp <= 0x1F64F) or // Misc Symbols and Pictographs, Emoticons
        (cp >= 0x1F680 and cp <= 0x1F6FF) or // Transport and Map Symbols
        (cp >= 0x1F900 and cp <= 0x1F9FF) or // Supplemental Symbols and Pictographs
        (cp >= 0x1FA00 and cp <= 0x1FA6F) or // Chess Symbols
        (cp >= 0x1FA70 and cp <= 0x1FAFF); // Symbols and Pictographs Extended-A
}

/// Calculate display width of a UTF-8 string
pub fn stringWidth(str: []const u8) usize {
    var width: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };

    while (iter.nextCodepoint()) |cp| {
        width += codePointWidth(cp);
    }

    return width;
}

test "ASCII characters have width 1" {
    try std.testing.expectEqual(@as(u2, 1), codePointWidth('a'));
    try std.testing.expectEqual(@as(u2, 1), codePointWidth('Z'));
    try std.testing.expectEqual(@as(u2, 1), codePointWidth('0'));
    try std.testing.expectEqual(@as(u2, 1), codePointWidth(' '));
    try std.testing.expectEqual(@as(u2, 1), codePointWidth('!'));
}

test "control characters have width 0" {
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x00)); // NUL
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x1F)); // Unit Separator
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x7F)); // DEL
}

test "combining marks have width 0" {
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x0300)); // Combining Grave Accent
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x0301)); // Combining Acute Accent
}

test "zero-width characters have width 0" {
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x200B)); // Zero Width Space
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x200C)); // Zero Width Non-Joiner
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x200D)); // Zero Width Joiner (ZWJ)
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x2060)); // Word Joiner
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0xFEFF)); // Zero Width No-Break Space
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0xFE0F)); // Variation Selector 16 (emoji presentation)
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0xFE0E)); // Variation Selector 15 (text presentation)
}

test "CJK characters have width 2" {
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x4E00)); // CJK Unified Ideograph
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x3042)); // Hiragana A
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x30A2)); // Katakana A
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0xAC00)); // Hangul Syllable
}

test "emoji have width 2" {
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x1F600)); // Grinning Face
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x1F680)); // Rocket
}

test "fullwidth forms have width 2" {
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0xFF01)); // Fullwidth Exclamation Mark
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0xFF21)); // Fullwidth Latin Capital Letter A
}

test "stringWidth" {
    try std.testing.expectEqual(@as(usize, 5), stringWidth("Hello"));
    try std.testing.expectEqual(@as(usize, 2), stringWidth("中")); // One CJK char = width 2
    try std.testing.expectEqual(@as(usize, 6), stringWidth("Hi中文")); // H(1) + i(1) + 中(2) + 文(2) = 6
}

test "stringWidth with combining marks" {
    // "é" as "e" + combining acute = e(1) + combining(0) = 1
    try std.testing.expectEqual(@as(usize, 1), stringWidth("e\xCC\x81"));
    // "café" = c(1) + a(1) + f(1) + e(1) + combining(0) = 4
    try std.testing.expectEqual(@as(usize, 4), stringWidth("cafe\xCC\x81"));
}

test "stringWidth with ZWJ sequences" {
    // ZWJ has width 0
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x200D));
    // Note: Complex ZWJ emoji sequences are NOT fully supported in MVP
    // Each codepoint is measured individually, so 👨‍👩‍👧 (family emoji)
    // would count as sum of individual emoji widths, not 2
}

test "variation selectors have width 0" {
    // Text presentation selector (VS15)
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0xFE0E));
    // Emoji presentation selector (VS16)
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0xFE0F));
}

test "more CJK ranges" {
    // CJK Radicals Supplement
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x2E80));
    // Kangxi Radicals
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x2F00));
    // CJK Symbols and Punctuation
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x3000)); // Ideographic space
    // Yi Syllables
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0xA000));
}

test "more emoji ranges" {
    // Miscellaneous Symbols and Pictographs
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x1F300)); // Cyclone
    // Emoticons
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x1F600)); // Grinning Face
    // Transport and Map Symbols
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x1F680)); // Rocket
    // Supplemental Symbols and Pictographs
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x1F900)); // Face with monocle (approx)
}

test "extended combining marks" {
    // Combining Diacritical Marks Extended
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x1AB0));
    // Combining Diacritical Marks Supplement
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x1DC0));
    // Combining Diacritical Marks for Symbols
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x20D0));
    // Combining Half Marks
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0xFE20));
}
