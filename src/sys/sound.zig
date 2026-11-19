//! Plays WAV sounds through the system, one at a time like it does, on a thread of its own so
//! asking never stalls the caller, even on a game's render thread.

const std = @import("std");
const native = @import("win/sound.zig");

/// The ones the user picks in Windows' sound settings.
pub const System = enum { default, info, warning, @"error", question, notification };

/// Starting a sound stops the last one.
pub const Player = native.Player;

/// A RIFF WAVE file, the only kind it plays.
pub fn isWav(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE");
}

/// A tiny silent WAV, for tests.
pub fn silence() [48]u8 {
    var wav: [48]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 40, .little);
    @memcpy(wav[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, wav[22..24], 1, .little); // mono
    std.mem.writeInt(u32, wav[24..28], 8000, .little);
    std.mem.writeInt(u32, wav[28..32], 16000, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 4, .little);
    @memset(wav[44..48], 0);
    return wav;
}

test "plays WAVs and nothing else" {
    try std.testing.expect(!isWav("nope"));
    const wav = silence();
    try std.testing.expect(isWav(&wav));

    const player = try Player.create(std.testing.allocator);
    defer player.destroy();
    try std.testing.expectError(error.InvalidSound, player.play("RIFF....AVI "));
    try player.play(&wav);
    try player.play(&wav); // the first's copy goes once this one starts
    player.stop();
}
